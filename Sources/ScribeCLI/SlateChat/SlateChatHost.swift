import Foundation
import Logging
import ScribeCore
import ScribeLLM
import SlateCore
import Synchronization

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

// MARK: - Model turn interrupt flag

/// Cooperative abort for Ctrl+C during an assistant/tool round without
/// cancelling the long-lived coordinator task.
private final class ModelTurnInterruptFlag: Sendable {
  private let lock = Mutex(false)

  func clear() { lock.withLock { $0 = false } }
  func request() { lock.withLock { $0 = true } }
  func peek() -> Bool { lock.withLock { $0 } }

  func logState(_ logger: Logger, tag: String) {
    let val = peek()
    logger.trace("chat.interrupt-flag.\(tag)", metadata: ["value": "\(val)"])
  }
}

// MARK: - Host event channel

/// Events the coordinator task sends to the host for rendering.
enum HostEvent: Sendable {
  case transcript(TranscriptEvent)
  case modelTurnRunning(Bool)
  case coordinatorFinished
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

        let persistURL = self.sessionPersistenceURL

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

        let interruptFlag = self.modelInterruptFlag
        let sessionLog = self.log
        let eventQueue = self.eventQueue
        let sidUUID = self.sessionId
        let createdAt = self.sessionCreatedAt
        self.coordinatorTask = Task {
          [
            configuration, systemPrompt, gate, resumeSnapshot = self.resumeMessages,
            interruptFlag, sessionLog, eventQueue, persistURL, sidUUID, createdAt
          ] in

          func enqueue(_ event: HostEvent) {
            eventQueue.enqueue(event)
          }

          func persistNew(from agent: ScribeAgent, since count: Int) async {
            let newMessages = await agent.messages(since: count)
            guard !newMessages.isEmpty else { return }
            do {
              try ChatSessionStore.appendMessages(newMessages, to: persistURL)
              let total = await agent.messages.count
              sessionLog.trace(
                "chat.persist.append",
                metadata: [
                  "new": "\(newMessages.count)",
                  "total": "\(total)",
                  "path": "\(persistURL.path)",
                ])
            } catch {
              sessionLog.error(
                "chat.persist.fail",
                metadata: [
                  "path": "\(persistURL.path)",
                  "err": "\(error.localizedDescription)",
                ])
            }
          }

          do {
            let initialMessages: [Components.Schemas.ChatMessage]
            if !resumeSnapshot.isEmpty {
              guard resumeSnapshot.first?.role == .system else {
                throw ScribeError.sessionCorrupted(
                  reason: "Resumed conversation must begin with a system message.")
              }
              initialMessages = resumeSnapshot
            } else {
              initialMessages = [.init(role: .system, content: systemPrompt)]
            }

            let agent = try ScribeAgent(
              configuration: configuration,
              systemPrompt: systemPrompt,
              initialMessages: initialMessages
            )

            // Write metadata on first persist (new sessions only).
            if resumeSnapshot.isEmpty {
              let cwd = FileManager.default.currentDirectoryPath
              let meta = ChatSessionMetadata(
                id: sidUUID,
                createdAt: createdAt,
                model: configuration.agentModel,
                cwd: cwd,
                baseURL: configuration.serverURL,
                scribeVersion: GitVersion.hash
              )
              try? ChatSessionStore.saveMetadata(meta, to: persistURL)
            }

            try ChatSessionStore.appendMessages(initialMessages, to: persistURL)
            var persistedCount = initialMessages.count

            let msgCount = initialMessages.count
            sessionLog.debug(
              "event=chat.coordinator.start messages=\(msgCount) resumed=\(!resumeSnapshot.isEmpty)")

            let tracker = TokenTracker(
              contextWindow: configuration.contextWindow,
              threshold: configuration.contextWindowThreshold
            )

            while true {
              guard let line = await gate.nextLine() else {
                sessionLog.info("event=chat.user.eof reason=stdin-closed")
                break
              }
              let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
              if trimmed == "exit" {
                sessionLog.notice("event=chat.user.exit-command")
                break
              }
              if trimmed.isEmpty {
                sessionLog.trace("event=chat.user.empty-skip")
                continue
              }

              // Record user submission into transcript.
              enqueue(.transcript(.userSubmitted(trimmed)))
              sessionLog.debug("event=agent.turn.dispatch chars=\(trimmed.count)")

              interruptFlag.clear()
              interruptFlag.logState(sessionLog, tag: "cleared-for-new-turn")
              enqueue(.modelTurnRunning(true))
              defer { enqueue(.modelTurnRunning(false)) }

              let options = AgentRunOptions(
                shouldAbortTurn: {
                  let v = interruptFlag.peek()
                  if v { sessionLog.trace("chat.interrupt-flag.polled", metadata: ["value": "true"]) }
                  return v
                }
              )

              do {
                let ts = await agent.prompt(trimmed, options: options, log: sessionLog)
                for await event in ts.events {
                  if case .usage(let usage, _) = event { tracker.accumulate(usage: usage) }
                  enqueue(.transcript(event))
                }
                let result = try await ts.result.value
                switch result.outcome {
                case .completed:
                  sessionLog.info("event=agent.turn.end status=completed")
                  tracker.logStatus(logger: sessionLog)
                case .interrupted:
                  sessionLog.notice("event=agent.turn.end status=interrupted")
                  enqueue(.transcript(.turnInterrupted))
                case .toolRoundLimit(let max):
                  sessionLog.notice("event=agent.turn.end status=tool-round-limit limit=\(max)")
                  enqueue(.transcript(.turnInterrupted))
                }
              } catch {
                let se = (error as? ScribeError) ?? .generic(String(describing: error))
                sessionLog.error(
                  "event=agent.turn.end status=error err=\"\(se.errorDescription ?? String(describing: se))\"")
                enqueue(.transcript(.harnessError(se)))
              }
              await persistNew(from: agent, since: persistedCount)
              persistedCount = await agent.messages.count

              // Turn complete — tell host to reconcile from agent.
              let committed = await agent.messages
              enqueue(.transcript(.reconcileFromAgent(committed)))
            }
            await persistNew(from: agent, since: persistedCount)
            let finalMsgCount = await agent.messages.count
            sessionLog.debug("event=chat.coordinator.end transcript_messages=\(finalMsgCount)")
          } catch {
            let scribeError = (error as? ScribeError) ?? .generic(String(describing: error))
            enqueue(.transcript(.harnessError(scribeError)))
            sessionLog.error(
              "chat.coordinator.fail",
              metadata: [
                "err": "\(scribeError.errorDescription ?? String(describing: scribeError))"
              ])
          }
          enqueue(.coordinatorFinished)
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
      let st = theme.style(for: section)
      let rendered = markdownRenderer.renderStreaming(
        text: streamingOpenLineRaw,
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

    case .reconcileFromAgent(let messages):
      // Discard streaming state and rebuild transcript from agent messages.
      transcriptLines = renderMessagesToTranscript(messages, theme: theme, renderer: markdownRenderer)
      streamingOpenLine = nil
      streamingOpenLineRaw = ""
      streamingSectionStartLineIndex = nil
      transcriptGeneration &+= 1
      flattenCache = TranscriptLayout.FlattenCache()
      renderWake?.requestRender()

    case .modelTurnRunning:
      break  // Handled by HostEvent.modelTurnRunning
    }
  }

  // MARK: - Submit effect dispatch

  /// Execute a `SubmitEffect` against the gate and interrupt flag.
  /// Returns `true` if the chat loop should stop.
  private func applySubmitEffect(
    _ effect: SubmitEffect,
    gate: UserLineGate
  ) -> Bool {
    switch effect {
    case .sendToGate(let text):
      Task { await gate.complete(text) }

    case .interruptAndSend(let text):
      modelInterruptFlag.request()
      modelInterruptFlag.logState(log, tag: "interrupt-and-send")
      Task { await gate.complete(text) }

    case .setQueued(let text):
      queuedTrayText = text

    case .clearQueued:
      queuedTrayText = nil

    case .interruptModel:
      modelInterruptFlag.request()
      modelInterruptFlag.logState(log, tag: "requested-by-ctrl-c")

    case .exitChat:
      return true

    case .none:
      break
    }
    renderWake?.requestRender()
    return false
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
