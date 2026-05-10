import Foundation
import Logging
import ScribeCore
import ScribeLLM
import SlateCore

// MARK: - User input gate

private actor UserLineGate {
  private var waiting: CheckedContinuation<String?, Never>?
  private var queue: [String] = []

  func nextLine() async -> String? {
    if !queue.isEmpty {
      return queue.removeFirst()
    }
    return await withCheckedContinuation { cont in
      waiting = cont
    }
  }

  func complete(_ line: String?) {
    if let cont = waiting {
      cont.resume(returning: line)
      waiting = nil
    } else if let line {
      queue.append(line)
    }
  }
}

// MARK: - Transcript flatten cache

extension TranscriptLayout {
  /// Cached flatten results to avoid re-wrapping completed transcript lines
  /// on every render frame.  Reset when width or generation changes.
  struct FlattenCache {
    var wrapWidth: Int = -1
    var completedLogicalLines: Int = 0
    var completedFlat: [TLine] = []
    var lastGeneration: Int = -1

    /// Recompute flattened rows for the given completed + optional open line.
    /// Only wraps new lines since the last call when the set of completed lines grows.
    static func flatten(
      cache: inout FlattenCache,
      completed: [TLine],
      open: TLine?,
      width: Int,
      generation: Int
    ) -> [TLine] {
      if width != cache.wrapWidth || generation != cache.lastGeneration {
        cache = FlattenCache()
        cache.wrapWidth = width
        cache.lastGeneration = generation
        cache.completedFlat = TranscriptLayout.flattenedRows(from: completed, width: width)
        cache.completedLogicalLines = completed.count
      } else if completed.count < cache.completedLogicalLines {
        // Lines were removed (truncation) — full recompute.
        cache.completedFlat = TranscriptLayout.flattenedRows(from: completed, width: width)
        cache.completedLogicalLines = completed.count
      } else if completed.count > cache.completedLogicalLines {
        // New lines appended — only wrap the new ones.
        let start = cache.completedLogicalLines
        if start < completed.count {
          let newSlice = completed[start...]
          cache.completedFlat.append(
            contentsOf: TranscriptLayout.flattenedRows(from: Array(newSlice), width: width))
        }
        cache.completedLogicalLines = completed.count
      }

      if let open {
        return cache.completedFlat + TranscriptLayout.flattenedRows(from: [open], width: width)
      }
      return cache.completedFlat
    }
  }
}

// MARK: - SlateChatHost

@MainActor
internal final class SlateChatHost {

  private let configuration: ScribeConfig
  private let systemPrompt: String
  private let resumeMessages: [Components.Schemas.ChatMessage]
  private let sessionPersistenceURL: URL
  private let sessionId: UUID
  private let sessionCreatedAt: Date

  // Extracted concerns
  private var inputHandler = TerminalInputHandler()
  private var submitCoordinator = SubmitCoordinator()
  private var viewport = TranscriptViewport()

  // MARK: - Transcript state (source of truth for rendering)

  /// Completed transcript lines (user messages, finalized assistant turns, tool output).
  private var transcriptLines: [TLine] = []
  /// Open line being built during streaming (nil when idle).
  private var streamingOpenLine: TLine? = nil
  private var streamingOpenLineRaw: String = ""
  private var streamingSectionStartLineIndex: Int? = nil
  private var currentStreamingSection: AssistantStreamSection = .answer
  /// Bumped when transcript structure changes (for FlattenCache invalidation).
  private var transcriptGeneration: Int = 0

  private var flattenCache = TranscriptLayout.FlattenCache()

  // MARK: - UI state

  private var modelBusy: Bool = false
  private var coordinatorFinished: Bool = false
  private var queuedTrayText: String? = nil
  private var banner: BannerSnapshot? = nil
  private var contextWindow: Int? = nil

  // Usage tracking
  private var usageTurnPrompt: Int = 0
  private var usageTurnCompletion: Int = 0
  private var usageTurnTotal: Int = 0
  private var usageSessionPrompt: Int = 0
  private var usageSessionCompletion: Int = 0
  private var usageSessionTotal: Int = 0
  private var usageHUD: UsageHUDSnapshot? = nil

  // MARK: - Coordinator communication

  /// Thread-safe event queue for coordinator → host communication.
  private final class EventQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [HostEvent] = []

    func enqueue(_ event: HostEvent) {
      lock.withLock { events.append(event) }
    }

    func drain() -> [HostEvent] {
      lock.withLock {
        let copy = events
        events = []
        return copy
      }
    }
  }

  private let eventQueue = EventQueue()
  private let markdownRenderer: MarkdownRenderer = SwiftMarkdownRenderer()
  private let theme: CLITheme = .default

  private var renderWake: ExternalWake?
  private var llmWaitAnimationFrame: Int = 0
  private var spinnerTask: Task<Void, Never>?
  private var coordinatorTask: Task<Void, Never>?
  private let modelInterruptFlag = ModelTurnInterruptFlag()
  private let log: Logger

  init(
    configuration: ScribeConfig,
    systemPrompt: String,
    resumeMessages: [Components.Schemas.ChatMessage],
    sessionPersistenceURL: URL,
    sessionId: UUID,
    sessionCreatedAt: Date,
    log: Logger
  ) {
    self.configuration = configuration
    self.systemPrompt = systemPrompt
    self.resumeMessages = resumeMessages
    self.sessionPersistenceURL = sessionPersistenceURL
    self.sessionId = sessionId
    self.sessionCreatedAt = sessionCreatedAt
    self.log = log
  }

  deinit {
    spinnerTask?.cancel()
  }

  func run() async throws {
    var slate = try Slate()
    let gate = UserLineGate()

    await slate.subscribe(
      prepare: { [self] wake in
        self.renderWake = wake
        self.contextWindow = self.configuration.contextWindow

        // Replay resume messages into transcript if resuming.
        if !self.resumeMessages.isEmpty {
          self.transcriptLines = renderMessagesToTranscript(
            self.resumeMessages, theme: self.theme, renderer: self.markdownRenderer)
        }

        let cwd = FileManager.default.currentDirectoryPath
        self.banner = BannerSnapshot(
          baseURL: self.configuration.serverURL,
          model: self.configuration.agentModel,
          cwd: cwd,
          scribeVersion: GitVersion.hash,
          gitBranch: nil,
          sessionId: self.sessionId.uuidString)

        // Detect git branch asynchronously.
        let baseURL = self.configuration.serverURL
        let model = self.configuration.agentModel
        let version = GitVersion.hash
        let sid = self.sessionId.uuidString
        Task.detached(priority: .background) { [weak self] in
          if let branch = SlateChatHost.detectGitBranch(cwd: cwd) {
            await MainActor.run {
              self?.banner = BannerSnapshot(
                baseURL: baseURL,
                model: model,
                cwd: cwd,
                scribeVersion: version,
                gitBranch: branch,
                sessionId: sid)
            }
          }
        }

        let eventQueue = self.eventQueue
        let sessionLog = self.log
        let persistence = SessionPersistence(
          url: self.sessionPersistenceURL,
          sessionId: self.sessionId,
          createdAt: self.sessionCreatedAt
        )

        // Bridge UserLineGate → AsyncStream<String> for the coordinator.
        let (inputStream, inputContinuation) = AsyncStream<String>.makeStream()
        let bridgeGate = gate
        let coordConfig = self.configuration
        let coordSystemPrompt = self.systemPrompt
        let coordResumeMessages = self.resumeMessages
        self.coordinatorTask = Task { [inputStream, interruptFlag = self.modelInterruptFlag] in
          // Feed gate lines into the stream from this detached context.
          let bridgeTask = Task {
            while let line = await bridgeGate.nextLine() {
              inputContinuation.yield(line)
            }
            inputContinuation.finish()
          }
          defer { bridgeTask.cancel() }

          do {
            let coordinator = try ChatCoordinator(
              configuration: coordConfig,
              systemPrompt: coordSystemPrompt,
              initialMessages: coordResumeMessages,
              persistence: persistence,
              eventSink: { event in eventQueue.enqueue(event) },
              log: sessionLog
            )
            _ = await coordinator.run(
              input: inputStream,
              interruptFlag: interruptFlag
            )
          } catch {
            let se = (error as? ScribeError) ?? .generic(String(describing: error))
            eventQueue.enqueue(.transcript(.harnessError(se)))
            sessionLog.error(
              "chat.coordinator.fail",
              metadata: [
                "err": "\(se.errorDescription ?? String(describing: se))"
              ])
          }
          eventQueue.enqueue(.coordinatorFinished)
        }

        self.spinnerTask?.cancel()
        self.spinnerTask = Task { [weak self] in
          while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(90))
            guard let self else { return }
            guard self.modelBusy else { continue }
            self.llmWaitAnimationFrame &+= 1
            self.renderWake?.requestRender()
          }
        }
        wake.requestRender()
      },
      coalesceMaxFPS: 60,
      onEvent: { slate, event in
        switch event {
        case .resize:
          slate.refreshWindowSize()

        case .external:
          break

        case .stdinBytes(let chunk):
          if self.coordinatorFinished { return .stop }
          if chunk.isEmpty {
            Task { await gate.complete(nil) }
            return .stop
          }

          var shouldStop = false
          let actions = self.inputHandler.handle(chunk)

          for action in actions {
            switch action {
            case .enter:
              let text = self.inputHandler.takeBuffer()
              self.submitCoordinator.setModelBusy(self.modelBusy)
              let effect = self.submitCoordinator.handleEnter(text: text)
              shouldStop = self.applySubmitEffect(effect, gate: gate)

            case .ctrlC:
              let (effect, recallText) = self.submitCoordinator.handleCtrlC()
              if let recall = recallText {
                self.inputHandler.setBuffer(recall)
                self.queuedTrayText = nil
                self.renderWake?.requestRender()
              }
              shouldStop = self.applySubmitEffect(effect, gate: gate)

            case .ctrlD:
              self.log.debug("chat.user.ctrl-d", metadata: ["action": "exit"])
              shouldStop = true

            case .arrowUp:
              self.viewport.queueScroll(by: -1)
            case .arrowDown:
              self.viewport.queueScroll(by: +1)
            case .pageUp:
              self.viewport.queuePageUp()
            case .pageDown:
              self.viewport.queuePageDown()
            case .home:
              self.viewport.queueGoToTop()
            case .end:
              self.viewport.queueGoToBottom()

            case .newline:
              self.log.debug(
                "chat.user.input.newline",
                metadata: [
                  "source": "paste-or-shift-enter",
                  "buffer_chars": "\(self.inputHandler.buffer.count)",
                  "has_queue": "\(self.submitCoordinator.queuedText != nil)",
                ])

            case .character, .backspace, .tab:
              break  // Buffer already mutated by TerminalInputHandler
            }
          }

          if shouldStop {
            Task { await gate.complete(nil) }
            return .stop
          }
        }

        // Auto-flush a queued tray message when the agent finishes a turn naturally.
        let nowBusy = self.modelBusy
        self.submitCoordinator.setModelBusy(nowBusy)
        let flushEffect = self.submitCoordinator.handleModelTurnEnd()
        if case .sendToGate(let text) = flushEffect {
          self.log.debug(
            "chat.queue.auto-flush",
            metadata: ["trigger": "busy-to-idle", "chars": "\(text.count)"])
          self.queuedTrayText = nil
          Task { await gate.complete(text) }
        }

        // Drain incoming events from coordinator before rendering.
        self.drainIncomingEvents()

        // Render frame.
        slate.with { grid in
          let scrCols = grid.cols
          let scrRows = grid.rows

          let prepareStart = Date()
          let completed = self.transcriptLines
          let open = self.streamingOpenLine
          let generation = self.transcriptGeneration
          let flatTranscript = TranscriptLayout.FlattenCache.flatten(
            cache: &self.flattenCache,
            completed: completed,
            open: open,
            width: scrCols,
            generation: generation)
          let contentRows = SlateChatRenderer.transcriptContentRows(
            cols: scrCols,
            rows: scrRows,
            banner: self.banner,
            usage: self.usageHUD,
            inputLine: self.inputHandler.buffer,
            waitingForLLM: self.modelBusy,
            queuedTrayText: self.queuedTrayText)
          _ = self.viewport.resolve(flatCount: flatTranscript.count, contentRows: contentRows)
          let transcriptTailStart = self.viewport.firstVisibleRow
          let prepareMs = Int(Date().timeIntervalSince(prepareStart) * 1000)

          let submitStart = Date()
          SlateChatRenderer.render(
            into: &grid,
            cols: scrCols,
            rows: scrRows,
            flattenedTranscript: flatTranscript,
            transcriptTailStart: transcriptTailStart,
            banner: self.banner,
            usage: self.usageHUD,
            inputLine: self.inputHandler.buffer,
            llmWaitAnimationFrame: self.llmWaitAnimationFrame,
            waitingForLLM: self.modelBusy,
            queuedTrayText: self.queuedTrayText,
            theme: .default)
          let submitMs = Int(Date().timeIntervalSince(submitStart) * 1000)
          let totalMs = prepareMs &+ submitMs
          if totalMs >= 50 {
            self.log.debug(
              "chat.render.slow",
              metadata: [
                "elapsed_ms": "\(totalMs)",
                "prepare_ms": "\(prepareMs)",
                "submit_ms": "\(submitMs)",
                "flat_rows": "\(flatTranscript.count)",
                "cols": "\(scrCols)",
                "rows": "\(scrRows)",
                "model_busy": "\(nowBusy)",
                "queue_chars": "\(self.submitCoordinator.queuedText?.count ?? 0)",
                "buffer_chars": "\(self.inputHandler.buffer.count)",
              ])
          }
        }
        return self.coordinatorFinished ? .stop : .continue
      })

    spinnerTask?.cancel()
    spinnerTask = nil
    renderWake = nil

    coordinatorTask?.cancel()
    await gate.complete(nil)
  }

  // MARK: - Event draining

  private func drainIncomingEvents() {
    let events = eventQueue.drain()
    for event in events {
      switch event {
      case .transcript(let te):
        handleTranscriptEvent(te)
      case .modelTurnRunning(let running):
        modelBusy = running
        if running {
          usageTurnPrompt = 0
          usageTurnCompletion = 0
          usageTurnTotal = 0
          if var u = usageHUD {
            u.roundPrompt = nil
            u.roundCompletion = nil
            u.roundTotal = nil
            u.turnPrompt = 0
            u.turnCompletion = 0
            u.turnTotal = 0
            u.outputTokensPerSecond = nil
            u.reasoningTokens = nil
            u.cachedPromptTokens = nil
            usageHUD = u
          }
        } else {
          // Model turn ended — trigger a delayed render so the final frame
          // catches the transition.
          if let wake = renderWake {
            Task.detached(priority: .userInitiated) {
              try? await Task.sleep(for: .milliseconds(50))
              wake.requestRender()
            }
          }
        }
      case .coordinatorFinished:
        coordinatorFinished = true
      }
    }
  }

  // MARK: - Transcript event handling

  private func handleTranscriptEvent(_ event: TranscriptEvent) {
    switch event {
    case .enterAssistantSection(let section, let previous):
      // Finalize previous open line if any.
      if let open = streamingOpenLine {
        transcriptLines.append(open)
        streamingOpenLine = nil
      }
      if previous != nil {
        if previous == .reasoning && section == .answer {
          transcriptLines.append(TLine(spans: []))
        }
      } else {
        if let last = transcriptLines.last, isUserSubmissionLine(last) {
          transcriptLines.append(TLine(spans: []))
        }
      }
      let header = TLine(
        spans: [
          StyledSpan(
            fg: theme.scribePrefix, bg: theme.background, bold: false, text: "scribe:")
        ])
      transcriptLines.append(header)
      switch section {
      case .reasoning:
        transcriptLines.append(
          TLine(
            spans: [
              StyledSpan(
                fg: theme.sectionLabel, bg: theme.background, bold: false,
                text: "  · reasoning")
            ]))
      case .answer:
        transcriptLines.append(
          TLine(
            spans: [
              StyledSpan(
                fg: theme.sectionLabel, bg: theme.background, bold: false,
                text: "  · answer")
            ]))
      }
      streamingOpenLine = TLine(spans: [])
      streamingOpenLineRaw = ""
      streamingSectionStartLineIndex = transcriptLines.count
      currentStreamingSection = section
      renderWake?.requestRender()

    case .appendAssistantText(let section, let text):
      if streamingOpenLine == nil {
        streamingOpenLine = TLine(spans: [])
        streamingOpenLineRaw = ""
      }
      streamingOpenLineRaw += text
      currentStreamingSection = section

      // When the user has scrolled up, skip per-chunk rendering — the
      // streaming section isn't visible.  Accumulate raw text only; the
      // next chunk after scrolling back (or finalize) will catch up.
      guard viewport.followingLive else { return }

      let st = theme.style(for: section)

      // Only render the visible tail during streaming — the full accumulated
      // text is re-parsed with block-level markdown at finalize anyway.
      // Keeps per-chunk work bounded to O(screen) instead of O(total-response).
      let maxVisibleLogicalLines = 200  // generous: 2-4× a typical terminal
      let tailText: String = {
        let allLines = streamingOpenLineRaw.split(
          separator: "\n", omittingEmptySubsequences: false)
        guard allLines.count > maxVisibleLogicalLines else {
          return streamingOpenLineRaw
        }
        return allLines.suffix(maxVisibleLogicalLines).joined(separator: "\n")
      }()

      let rendered = markdownRenderer.renderStreaming(
        text: tailText,
        baseFG: st.fg,
        baseBold: st.bold,
        theme: section == .reasoning ? .grayscale : theme.markdown
      )
      if let startIdx = streamingSectionStartLineIndex {
        let removeCount = max(0, transcriptLines.count - startIdx)
        if removeCount > 0 {
          transcriptLines.removeLast(removeCount)
          transcriptGeneration &+= 1
        }
      }
      if rendered.isEmpty {
        streamingOpenLine = TLine(spans: [])
      } else {
        transcriptLines.append(contentsOf: rendered.dropLast())
        streamingOpenLine = rendered.last!
      }
      renderWake?.requestRender()

    case .finalizeAssistantStream:
      // Re-render accumulated text with full block-level markdown.
      if streamingSectionStartLineIndex != nil {
        let section = currentStreamingSection
        let st = theme.style(for: section)
        let mdTheme = section == .reasoning ? MarkdownTheme.grayscale : theme.markdown
        let fullRender = markdownRenderer.render(
          text: streamingOpenLineRaw,
          baseFG: st.fg,
          baseBold: st.bold,
          theme: mdTheme
        )
        if let startIdx = streamingSectionStartLineIndex {
          let removeCount = max(0, transcriptLines.count - startIdx)
          if removeCount > 0 {
            transcriptLines.removeLast(removeCount)
            transcriptGeneration &+= 1
          }
          if fullRender.isEmpty {
            streamingOpenLine = TLine(spans: [])
          } else {
            transcriptLines.append(contentsOf: fullRender.dropLast())
            streamingOpenLine = fullRender.last!
          }
        }
      }
      if let open = streamingOpenLine {
        transcriptLines.append(open)
        streamingOpenLine = nil
      }
      streamingOpenLineRaw = ""
      streamingSectionStartLineIndex = nil
      renderWake?.requestRender()

    case .emptyAssistantTurn:
      let lineA = TLine(
        spans: [
          StyledSpan(
            fg: theme.scribePrefix, bg: theme.background, bold: false, text: "scribe:")
        ])
      let lineB = TLine(
        spans: [
          StyledSpan(
            fg: theme.emptyTurn, bg: theme.background, bold: false, text: "(empty turn)")
        ])
      transcriptLines.append(lineA)
      transcriptLines.append(lineB)
      renderWake?.requestRender()

    case .usage(let usage, let tps):
      guard let triple = usage.scribeReportedPromptCompletionTotal else { break }
      usageTurnPrompt += triple.prompt
      usageTurnCompletion += triple.completion
      usageTurnTotal += triple.total
      usageSessionPrompt += triple.prompt
      usageSessionCompletion += triple.completion
      usageSessionTotal += triple.total
      let pct: Int? = {
        guard let cw = contextWindow, cw > 0, triple.prompt > 0 else { return nil }
        return min(100, Int(Double(triple.prompt) / Double(cw) * 100))
      }()
      usageHUD = UsageHUDSnapshot(
        roundPrompt: triple.prompt,
        roundCompletion: triple.completion,
        roundTotal: triple.total,
        turnPrompt: usageTurnPrompt,
        turnCompletion: usageTurnCompletion,
        turnTotal: usageTurnTotal,
        sessionPrompt: usageSessionPrompt,
        sessionCompletion: usageSessionCompletion,
        sessionTotal: usageSessionTotal,
        reasoningTokens: usage.completionTokensDetails?.reasoningTokens,
        cachedPromptTokens: usage.promptTokensDetails?.cachedTokens,
        outputTokensPerSecond: tps,
        contextWindow: contextWindow,
        contextWindowUsedPercent: pct
      )
      renderWake?.requestRender()

    case .blankLine:
      transcriptLines.append(TLine(spans: []))
      renderWake?.requestRender()

    case .toolRoundHeader(let round, let toolNames):
      let names = toolNames.joined(separator: ", ")
      let line = TLine(spans: [
        StyledSpan(
          fg: theme.toolRoundHeader, bg: theme.background, bold: true,
          text: "tool round \(round) "),
        StyledSpan(
          fg: theme.toolNames, bg: theme.background, bold: false, text: names),
      ])
      transcriptLines.append(line)
      renderWake?.requestRender()

    case .toolInvocation(let name, let arguments, let output):
      let argSummary = ToolInvocationFormatting.argumentSummary(name: name, argumentsJSON: arguments)
      let outputLines = ToolInvocationFormatting.outputLines(name: name, jsonOutput: output)
      var spans: [StyledSpan] = [
        StyledSpan(fg: theme.toolInvocation, bg: theme.background, bold: false, text: "▶ \(name)")
      ]
      if let argSummary {
        spans.append(
          StyledSpan(
            fg: theme.toolArgSummary, bg: theme.background, bold: false,
            text: " \(argSummary)"))
      }
      transcriptLines.append(TLine(spans: spans))
      for ol in outputLines {
        transcriptLines.append(
          TLine(
            spans: [
              StyledSpan(
                fg: theme.toolOutput, bg: theme.background, bold: false,
                text: "  \(ol)")
            ]))
      }
      renderWake?.requestRender()

    case .skippedUnreadableStreamLine:
      transcriptLines.append(
        TLine(
          spans: [
            StyledSpan(
              fg: theme.skippedStreamLine, bg: theme.background, bold: false,
              text: "(skipped one stream line: not valid completion JSON)")
          ]))
      renderWake?.requestRender()

    case .harnessError(let error):
      transcriptLines.append(
        TLine(
          spans: [
            StyledSpan(
              fg: theme.errorFG, bg: theme.background, bold: false,
              text: "error: \(error.errorDescription ?? String(describing: error))")
          ]))
      renderWake?.requestRender()

    case .turnInterrupted:
      transcriptLines.append(
        TLine(
          spans: [
            StyledSpan(
              fg: theme.interruptedFG, bg: theme.background, bold: false,
              text: "(interrupted)")
          ]))
      streamingOpenLine = nil
      streamingOpenLineRaw = ""
      streamingSectionStartLineIndex = nil
      renderWake?.requestRender()

    case .userSubmitted(let text):
      guard !text.isEmpty else { return }
      let logicalLines =
        text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
      transcriptLines.append(
        TLine(
          spans: [
            StyledSpan(
              fg: theme.userPrefix, bg: theme.background, bold: false,
              text: "you:")
          ]))
      for row in logicalLines {
        if row.isEmpty {
          transcriptLines.append(TLine(spans: []))
          continue
        }
        transcriptLines.append(
          TLine(
            spans: [
              StyledSpan(
                fg: theme.userBody, bg: theme.background, bold: false,
                text: "  \(row)")
            ]))
      }
      renderWake?.requestRender()

    case .turnComplete(let referenceMessages):
      // Finalize any dangling streaming state (should already be done, defensive).
      if let open = streamingOpenLine {
        transcriptLines.append(open)
      }
      streamingOpenLine = nil
      streamingOpenLineRaw = ""
      streamingSectionStartLineIndex = nil

      // Compare streaming render against batch render for drift detection.
      let batchLines = renderMessagesToTranscript(
        referenceMessages, theme: theme, renderer: markdownRenderer)
      if transcriptLines != batchLines {
        let sc = transcriptLines.count
        let bc = batchLines.count
        let driftMeta: Logger.Metadata = [
          "streaming_count": .string("\(sc)"),
          "batch_count": .string("\(bc)"),
        ]
        log.warning("transcript.streaming-drift", metadata: driftMeta)
        // Log every differing line for easy test-casing.
        let maxCount = max(sc, bc)
        for idx in 0..<maxCount {
          let sLine = idx < sc ? transcriptLines[idx] : nil
          let bLine = idx < bc ? batchLines[idx] : nil
          if sLine != bLine {
            let detailMeta: Logger.Metadata = [
              "index": .string("\(idx)"),
              "streaming": .string(sLine.map { spansToDebugString($0) } ?? "(missing)"),
              "batch": .string(bLine.map { spansToDebugString($0) } ?? "(missing)"),
            ]
            log.warning("transcript.streaming-drift.detail", metadata: detailMeta)
          }
        }
      }
      renderWake?.requestRender()
    }
  }

  // MARK: - Submit effect dispatch

  /// Execute a `SubmitEffect` against the gate and interrupt flag.
  /// Returns `true` if the chat loop should stop.
  private func applySubmitEffect(
    _ effect: SubmitEffect,
    gate: UserLineGate
  ) -> Bool {
    var state = HostSubmitState(queuedTrayText: queuedTrayText)
    let fx = HostSubmitState.apply(effect, to: &state)
    queuedTrayText = state.queuedTrayText

    if let tag = fx.interruptLogTag {
      modelInterruptFlag.request()
      modelInterruptFlag.logState(log, tag: tag)
    }
    if let text = fx.gateText {
      Task { await gate.complete(text) }
    }
    if fx.needsDelayedRenderWake {
      // The external wake from requestRender (below) fires through the
      // throttler immediately, often before the coordinator Task has
      // enqueued its .userSubmitted / .modelTurnRunning events.  Schedule
      // a second wake after the throttle interval so the throttler emits
      // a fresh tick that is guaranteed to land after the coordinator
      // has populated the event queue.
      scheduleDelayedRenderWake()
    }
    if fx.shouldExit {
      return true
    }
    renderWake?.requestRender()
    return false
  }

  /// Request a render after a brief delay, giving the coordinator Task
  /// time to enqueue transcript events before the next frame is painted.
  ///
  /// The delay is set slightly longer than the throttle interval
  /// (1/60 ≈ 16.67 ms) so the throttler emits this tick as a fresh
  /// external event rather than coalescing it with the preceding one.
  private func scheduleDelayedRenderWake() {
    let wake = renderWake
    Task {
      try? await Task.sleep(for: .milliseconds(20))
      wake?.requestRender()
    }
  }

  // MARK: - Helpers

  private func isUserSubmissionLine(_ line: TLine) -> Bool {
    guard line.spans.count == 1 else { return false }
    let s = line.spans[0]
    return !s.bold
      && s.fg == theme.userPrefix
      && s.bg == theme.background
      && s.text == "you:"
  }

  /// Renders a TLine into a compact debug string for log output.
  private func spansToDebugString(_ line: TLine) -> String {
    line.spans.map { $0.text }.joined()
  }

  // MARK: - Git branch detection

  /// Runs `git branch --show-current` in `cwd` and returns the branch name,
  /// or nil if not in a git repo.
  private nonisolated static func detectGitBranch(cwd: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["branch", "--show-current"]
    process.currentDirectoryURL = URL(fileURLWithPath: cwd)
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else { return nil }
      let data = try pipe.fileHandleForReading.readToEnd() ?? Data()
      let branch = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return branch?.isEmpty == true ? nil : branch
    } catch {
      return nil
    }
  }
}
