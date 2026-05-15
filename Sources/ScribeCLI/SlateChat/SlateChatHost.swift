import Foundation
import Logging
import ScribeCore
import SlateCore
import Synchronization

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

enum HostEvent: Sendable {
  case transcript(TranscriptEvent)
  case userSubmitted(String)
  case modelTurnRunning(Bool)
  case coordinatorFinished
}

extension TranscriptLayout {
  struct FlattenCache {
    var wrapWidth: Int = -1
    var completedLogicalLines: Int = 0
    var completedFlat: [TLine] = []
    var lastGeneration: Int = -1

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

@MainActor
internal final class SlateChatHost {

  private let configuration: ScribeConfig
  private let systemPrompt: String
  private let resumeMessages: [ScribeMessage]
  private let sessionPersistenceURL: URL
  private let sessionId: UUID
  private let sessionCreatedAt: Date

  private var inputHandler = TerminalInputHandler()
  private var submitCoordinator = SubmitCoordinator()
  private var viewport = TranscriptViewport()
  /// Current input mode: `.edit` for typing, `.read` for navigation/ladder.
  private var editMode: EditMode = .edit

  private var transcriptState = TranscriptState()
  private var flattenCache = TranscriptLayout.FlattenCache()

  private var inputBuffer: String = ""
  private var inPaste: Bool = false
  private var modelBusy: Bool = false
  private var coordinatorFinished: Bool = false
  private var queuedTrayTexts: [String] = []
  private var banner: BannerSnapshot? = nil
  private var contextWindow: Int? = nil

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
  private var coordinator: ChatCoordinator?
  private let log: Logger

  init(
    configuration: ScribeConfig,
    systemPrompt: String,
    resumeMessages: [ScribeMessage],
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
                if self.editMode == .edit { self.inputBuffer.append("\n") }
              } else if self.editMode == .read {
                self.log.debug("event=chat.mode.to-edit source=enter")
                self.editMode = .edit
              } else {
                let text = self.inputBuffer
                self.inputBuffer = ""
                self.submitCoordinator.setModelBusy(self.modelBusy)
                let effect = self.submitCoordinator.handleEnter(text: text)
                shouldStop = self.applySubmitEffect(effect, gate: gate)
              }

            case .ctrlC:
              if self.editMode == .edit {
                self.log.debug("event=chat.mode.to-read source=ctrl-c")
                self.editMode = .read
              } else {
                let (effect, recallText) = self.submitCoordinator.handleCtrlC()
                if let recall = recallText {
                  self.inputBuffer = recall
                  self.editMode = .edit
                  self.renderWake?.requestRender()
                }
                shouldStop = self.applySubmitEffect(effect, gate: gate)
              }

            case .escape:
              if self.editMode == .edit {
                self.log.debug("event=chat.mode.to-read source=escape")
                self.editMode = .read
              }

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

            case .shiftEnter:
              if self.editMode == .edit { self.inputBuffer.append("\n") }
              self.log.debug(
                "chat.user.input.shift-enter",
                metadata: [
                  "source": "shift-enter",
                  "buffer_chars": "\(self.inputBuffer.count)",
                  "has_queue": "\(!self.submitCoordinator.queuedTexts.isEmpty)",
                ])

            case .character(let ch):
              if self.editMode == .edit { self.inputBuffer.append(ch) }

            case .backspace:
              if !self.inPaste, self.editMode == .edit, !self.inputBuffer.isEmpty {
                self.inputBuffer.removeLast()
              }

            case .tab:
              if self.editMode == .edit { self.inputBuffer.append("    ") }
            }
          }

          if shouldStop {
            Task { await gate.complete(nil) }
            return .stop
          }
        }

        let nowBusy = self.modelBusy
        self.submitCoordinator.setModelBusy(nowBusy)
        // TODO: allow a plugin/hook to decide drain-all vs drain-one here.
        let drained = self.submitCoordinator.handleModelTurnEnd()
        if !drained.isEmpty {
          for text in drained {
            self.log.debug(
              "chat.queue.auto-flush",
              metadata: ["trigger": "busy-to-idle", "chars": "\(text.count)"])
          }
          self.queuedTrayTexts = self.submitCoordinator.queuedTexts
          for text in drained {
            Task { await gate.complete(text) }
          }
        }

        self.drainIncomingEvents()

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
            queuedTrayText: self.queuedTrayTexts.first,
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
            inputMode: self.editMode,
            llmWaitAnimationFrame: self.llmWaitAnimationFrame,
            waitingForLLM: self.modelBusy,
            queuedTrayText: self.queuedTrayTexts.first,
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
                "queue_chars": "\(self.submitCoordinator.queuedTexts.first?.count ?? 0)",
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
        if effects.needsRender {
          renderWake?.requestRender()
        }
      case .userSubmitted(let text):
        let effects = TranscriptController.applyUserSubmitted(
          text, state: &transcriptState, theme: theme)
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

  private func applySubmitEffect(
    _ effect: SubmitEffect,
    gate: UserLineGate
  ) -> Bool {
    var state = HostSubmitState(queuedTrayTexts: queuedTrayTexts)
    let fx = HostSubmitState.apply(effect, to: &state)
    queuedTrayTexts = state.queuedTrayTexts

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
      scheduleDelayedRenderWake()
    }
    if fx.shouldExit {
      return true
    }
    renderWake?.requestRender()
    return false
  }

  private func scheduleDelayedRenderWake() {
    let wake = renderWake
    Task {
      try? await Task.sleep(for: .milliseconds(20))
      wake?.requestRender()
    }
  }

  private func spansToDebugString(_ line: TLine) -> String {
    line.spans.map { $0.text }.joined()
  }

  private nonisolated static func detectGitBranch(cwd: String) -> String? {
    // TODO: Do something else here
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
