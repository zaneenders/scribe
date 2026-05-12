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
  private var streamContinuation: AsyncStream<String>.Continuation?

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
    // Also bridge to AsyncStream for ChatCoordinator.
    if let line {
      streamContinuation?.yield(line)
    } else {
      streamContinuation?.finish()
    }
  }

  func setStreamContinuation(_ cont: AsyncStream<String>.Continuation) {
    streamContinuation = cont
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

  private var transcriptState = TranscriptState()
  private var flattenCache = TranscriptLayout.FlattenCache()

  // MARK: - UI state

  private var inputBuffer: String = ""
  private var inPaste: Bool = false
  private var modelBusy: Bool = false
  private var coordinatorFinished: Bool = false
  private var queuedTrayText: String? = nil
  private var banner: BannerSnapshot? = nil
  private var contextWindow: Int? = nil

  // Usage tracking is in transcriptState — no separate fields needed.

  // MARK: - Coordinator communication

  /// Thread-safe event queue for coordinator → host communication.
  private final class EventQueue: Sendable {
    private let events: Mutex<[HostEvent]> = Mutex([])

    func enqueue(_ event: HostEvent) {
      events.withLock { $0.append(event) }
    }

    func drain() -> [HostEvent] {
      events.withLock {
        let copy = $0
        $0 = []
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
  /// Held so the Ctrl+C path can call `interrupt()` synchronously
  /// (`nonisolated` on the coordinator) without going through the agent's
  /// abort notifier directly. The host doesn't see `AbortNotifier` at all.
  private var coordinator: ChatCoordinator?
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
          self.transcriptState.lines = renderMessagesToTranscript(
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

        let (lineStream, lineCont) = AsyncStream<String>.makeStream()
        Task { await gate.setStreamContinuation(lineCont) }

        // Construct the coordinator eagerly — this throws if the resume
        // snapshot is malformed or the agent's transport can't be built.
        // Surface failures through the same event pipe `run()` would have
        // used so the TUI shows them; then skip the coordinator task.
        let coordinator: ChatCoordinator
        do {
          coordinator = try ChatCoordinator(
            configuration: configuration,
            systemPrompt: systemPrompt,
            resumeSnapshot: self.resumeMessages,
            log: self.log,
            enqueue: { [eventQueue] event in
              eventQueue.enqueue(event)
            },
            persistURL: persistURL,
            sessionId: self.sessionId,
            sessionCreatedAt: self.sessionCreatedAt,
            lines: lineStream
          )
        } catch {
          let scribeError = (error as? ScribeError) ?? .generic(String(describing: error))
          eventQueue.enqueue(.transcript(.harnessError(scribeError)))
          eventQueue.enqueue(.coordinatorFinished)
          self.log.error(
            "chat.coordinator.init.fail",
            metadata: [
              "err": "\(scribeError.errorDescription ?? String(describing: scribeError))"
            ])
          return
        }
        self.coordinator = coordinator
        self.coordinatorTask = Task {
          await coordinator.run()
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
            case .bracketedPasteStart:
              self.inPaste = true
            case .bracketedPasteEnd:
              self.inPaste = false

            case .enter:
              if self.inPaste {
                self.inputBuffer.append("\n")
              } else {
              let text = self.inputBuffer
              self.inputBuffer = ""
              self.submitCoordinator.setModelBusy(self.modelBusy)
              let effect = self.submitCoordinator.handleEnter(text: text)
              shouldStop = self.applySubmitEffect(effect, gate: gate)
              }

            case .ctrlC:
              let (effect, recallText) = self.submitCoordinator.handleCtrlC()
              if let recall = recallText {
                self.inputBuffer = recall
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

            case .escape:
              break

            case .shiftEnter:
              self.inputBuffer.append("\n")
              self.log.debug(
                "chat.user.input.newline",
                metadata: [
                  "source": "paste-or-shift-enter",
                  "buffer_chars": "\(self.inputBuffer.count)",
                  "has_queue": "\(self.submitCoordinator.queuedText != nil)",
                ])

            case .character(let ch):
              self.inputBuffer.append(ch)
            case .backspace:
              if !self.inputBuffer.isEmpty { self.inputBuffer.removeLast() }
            case .tab:
              self.inputBuffer.append("\t")
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
          var renderState = RenderState(
            transcriptLines: self.transcriptState.lines,
            streamingOpenLine: self.transcriptState.streamingOpenLine,
            generation: self.transcriptState.generation,
            flattenCache: self.flattenCache,
            banner: self.banner,
            usageHUD: self.transcriptState.usageHUD,
            inputBuffer: self.inputBuffer,
            modelBusy: self.modelBusy,
            queuedTrayText: self.queuedTrayText,
            llmWaitAnimationFrame: self.llmWaitAnimationFrame,
            viewport: self.viewport,
            cols: scrCols,
            rows: scrRows
          )
          let output = RenderLoop.buildFrame(state: &renderState)
          self.flattenCache = output.flattenCache
          self.viewport = output.viewport
          let prepareMs = Int(Date().timeIntervalSince(prepareStart) * 1000)

          let submitStart = Date()
          let spanGrid = SlateChatRenderer.buildGrid(
            cols: scrCols,
            rows: scrRows,
            flattenedTranscript: output.flattenedTranscript,
            transcriptTailStart: output.transcriptTailStart,
            banner: self.banner,
            usage: self.transcriptState.usageHUD,
            inputLine: self.inputBuffer,
            llmWaitAnimationFrame: self.llmWaitAnimationFrame,
            waitingForLLM: self.modelBusy,
            queuedTrayText: self.queuedTrayText,
            theme: .default)
          // Paint semantic spans into the terminal grid
          for (row, spanRow) in spanGrid.enumerated() {
            for (col, span) in spanRow.enumerated() {
              let ch = span.text.first ?? " "
              grid[column: col, row: row] = TerminalCell(
                glyph: ch,
                foreground: span.foreground,
                background: span.background,
                flags: span.flags)
            }
          }
          let submitMs = Int(Date().timeIntervalSince(submitStart) * 1000)
          let totalMs = prepareMs &+ submitMs
          if totalMs >= 50 {
            self.log.debug(
              "chat.render.slow",
              metadata: [
                "elapsed_ms": "\(totalMs)",
                "prepare_ms": "\(prepareMs)",
                "submit_ms": "\(submitMs)",
                "flat_rows": "\(output.flattenedTranscript.count)",
                "cols": "\(scrCols)",
                "rows": "\(scrRows)",
                "model_busy": "\(nowBusy)",
                "queue_chars": "\(self.submitCoordinator.queuedText?.count ?? 0)",
                "buffer_chars": "\(self.inputBuffer.count)",
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
        let effects = TranscriptController.apply(
          te,
          to: &transcriptState,
          theme: theme,
          renderer: markdownRenderer,
          followingLive: viewport.followingLive,
          contextWindow: contextWindow
        )
        // Drift detection for turnComplete
        if case .turnComplete(let referenceMessages) = te {
          let batchLines = renderMessagesToTranscript(
            referenceMessages, theme: theme, renderer: markdownRenderer)
          if transcriptState.lines != batchLines {
            let sc = transcriptState.lines.count
            let bc = batchLines.count
            let driftMeta: Logger.Metadata = [
              "streaming_count": .string("\(sc)"),
              "batch_count": .string("\(bc)"),
            ]
            log.warning("transcript.streaming-drift", metadata: driftMeta)
            let maxCount = max(sc, bc)
            for idx in 0..<maxCount {
              let sLine = idx < sc ? transcriptState.lines[idx] : nil
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
        }
        if effects.needsRender {
          renderWake?.requestRender()
        }
      case .modelTurnRunning(let running):
        modelBusy = running
        if running {
          transcriptState.usageTurnPrompt = 0
          transcriptState.usageTurnCompletion = 0
          transcriptState.usageTurnTotal = 0
          if var u = transcriptState.usageHUD {
            u.roundPrompt = nil
            u.roundCompletion = nil
            u.roundTotal = nil
            u.turnPrompt = 0
            u.turnCompletion = 0
            u.turnTotal = 0
            u.outputTokensPerSecond = nil
            u.reasoningTokens = nil
            u.cachedPromptTokens = nil
            transcriptState.usageHUD = u
          }
        } else {
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
      coordinator?.interrupt()
      log.trace(
        "chat.interrupt-flag.\(tag)",
        metadata: ["coordinator": coordinator == nil ? "nil" : "live"])
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
