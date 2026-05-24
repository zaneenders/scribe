import Foundation
import Logging
import ScribeCore
import SlateCore
import Synchronization
import SystemPackage

/// Bridges keystroke-driven submissions on the host's MainActor to the
/// coordinator's `AsyncStream<String>`. Synchronous — the host always calls
/// it from the MainActor and needs `setStreamContinuation` to land before
/// the next `complete(...)` (otherwise hot-swap could drop a queued
/// submission); a Mutex-backed class buys both that ordering and Sendable
/// access without the actor-hop race the previous actor implementation had.
private final class UserLineGate: @unchecked Sendable {
  private let state = Mutex<State>(State())

  private struct State {
    var streamContinuation: AsyncStream<String>.Continuation?
  }

  func complete(_ line: String?) {
    state.withLock { s in
      if let line {
        s.streamContinuation?.yield(line)
      } else {
        s.streamContinuation?.finish()
      }
    }
  }

  func setStreamContinuation(_ cont: AsyncStream<String>.Continuation) {
    state.withLock { $0.streamContinuation = cont }
  }
}

enum HostEvent: Sendable {
  case transcript(AgentEvent)
  case userSubmitted(String)
  case modelTurnRunning(Bool)
  case coordinatorFinished
}

/// Information conveyed back to the CLI after the chat host returns.
struct ChatExitInfo: Sendable {
  /// When the user forked or summarized at least once during the session,
  /// this carries the most recent post-swap session. The CLI uses it to
  /// point the resume hint at the session the user actually ended on.
  var forkedFromSessionId: UUID?
  var forkedToSessionId: UUID?
  var forkedToDirectory: FilePath?
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
  /// Messages restored from disk when resuming a session. For a fresh
  /// session this is empty and the host seeds the document with the
  /// system prompt.
  private let resumeMessages: [ScribeMessage]
  /// Session directory the document is currently writing to. Tracks the
  /// document — updated when the doc emits ``ChangeSet/identityChanged``.
  private var sessionDirectory: FilePath
  /// UUID of the active session. Tracks the document.
  private var sessionId: UUID
  /// Created-at timestamp of the active session.
  private var sessionCreatedAt: Date
  /// Input gate the coordinator consumes. Single instance for the whole
  /// host — `/fork` and `/tldr` mutate the doc in place without needing
  /// to retire and rebuild the coordinator.
  private var gate: UserLineGate = UserLineGate()
  /// The shared session document. Built async in ``run()`` before slate
  /// attaches; lives for the whole host lifetime. Both the coordinator
  /// (per-turn appends) and the picker (`/fork`, `/tldr`) mutate it.
  private var document: SessionDocument?
  /// Disk-backed persister handed to the document. Held so identity
  /// changes can be traced if needed.
  private var persister: FileSessionPersister?
  /// Background task that drains the doc's ``ChangeSet`` stream and
  /// dispatches identity changes onto the MainActor.
  private var documentObserverTask: Task<Void, Never>?

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
  /// False once `run()` begins teardown — picker side-effects must not
  /// mutate UI after the host is winding down.
  private var hostActive: Bool = true
  private var exitInfo: ChatExitInfo = ChatExitInfo()
  /// Boundary picker controller (driven by `/fork` and `/tldr`).
  private var pickerController = BoundaryPickerController()
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
  private let logger: Logger

  init(
    configuration: ScribeConfig,
    systemPrompt: String,
    resumeMessages: [ScribeMessage],
    sessionDirectory: FilePath,
    sessionId: UUID,
    sessionCreatedAt: Date,
    logger: Logger
  ) {
    self.configuration = configuration
    self.systemPrompt = systemPrompt
    self.resumeMessages = resumeMessages
    self.sessionDirectory = sessionDirectory
    self.sessionId = sessionId
    self.sessionCreatedAt = sessionCreatedAt
    self.logger = logger

    // Wire picker controller callbacks back to the host.
    pickerController.logger = logger
    pickerController.theme = theme
    pickerController.markdownRenderer = markdownRenderer
    pickerController.setModelBusy = { [weak self] busy in
      self?.modelBusy = busy
    }
    pickerController.requestRender = { [weak self] in
      self?.renderWake?.requestRender()
    }
    pickerController.isHostActive = { [weak self] in
      self?.hostActive ?? false
    }
    pickerController.currentSessionId = { [weak self] in
      self?.sessionId ?? UUID()
    }
    pickerController.enqueueHostEvent = { [weak self] event in
      self?.eventQueue.enqueue(event)
    }
    pickerController.restoreHostFromBackup = { [weak self] in
      guard let self, let backup = self.pickerController.backupForRestore else { return }
      self.transcriptState.lines = backup.lines
      self.transcriptState.generation = backup.generation &+ 1
      self.viewport = backup.viewport
      self.flattenCache = TranscriptLayout.FlattenCache()
    }
  }

  deinit {
    spinnerTask?.cancel()
  }

  func run() async throws -> ChatExitInfo {
    // Build the shared session document + disk persister BEFORE slate
    // attaches. The document is the single source of truth for messages
    // for both the agent (per-turn appends) and the picker (`/fork`,
    // `/tldr`). Subscribing to its change stream lets the host update
    // transcript / banner / exit-hint state without ever rebuilding the
    // coordinator.
    let cwdString = FilePath.currentDirectory.string
    let isNewSession = resumeMessages.isEmpty
    if !isNewSession, resumeMessages.first?.role != .system {
      throw ScribeError.sessionCorrupted(
        reason: "Resumed conversation must begin with a system message.")
    }
    let initialMessages: [ScribeMessage] = isNewSession
      ? [ScribeMessage(role: .system, content: systemPrompt)]
      : resumeMessages

    let persister = try await FileSessionPersister.open(
      sessionId: sessionId,
      directory: sessionDirectory,
      sessionCreatedAt: sessionCreatedAt,
      isNewSession: isNewSession,
      model: configuration.agentModel,
      cwd: cwdString,
      baseURL: configuration.serverURL,
      scribeVersion: GitVersion.hash,
      logger: logger
    )
    let document = SessionDocument(
      sessionId: sessionId,
      directory: sessionDirectory,
      initialMessages: initialMessages,
      persister: persister,
      logger: logger
    )
    if isNewSession {
      // The persister wrote metadata.json but not the seed; the doc
      // initialised its rope with `initialMessages` so we still need to
      // persist them once. Calling apply here would double-write since
      // the rope already holds them; go straight through the persister.
      try await persister.append(initialMessages)
    }
    self.document = document
    self.persister = persister

    // Spawn the doc-change observer. `.identityChanged` is the only event
    // the host reacts to (transcript snapshot, banner, exit hint);
    // `.appended` is already covered by the AgentEvent stream the
    // renderer consumes.
    let docChanges = await document.changes()
    self.documentObserverTask = Task { [weak self] in
      for await change in docChanges {
        guard case .identityChanged(let prev, let now, let dir, _) = change else { continue }
        await MainActor.run { [weak self] in
          self?.handleIdentityChange(previous: prev, sessionId: now, directory: dir)
        }
      }
    }

    var slate = try Slate()

    await slate.subscribe(
      prepare: { [self] wake in
        self.renderWake = wake
        self.contextWindow = self.configuration.contextWindow

        // Wire picker controller's document reference + configuration.
        self.pickerController.document = document
        self.pickerController.configuration = self.configuration

        // Initial transcript seed + banner setup, then start the
        // coordinator. The coordinator and document live for the host's
        // whole lifetime — no hot-swap dance on `/fork` / `/tldr`.
        self.refreshTranscriptFromInitialSeed(initialMessages)

        let cwd = FilePath.currentDirectory.string
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

        self.installCoordinator()

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
            self.gate.complete(nil)
            return .stop
          }

          var shouldStop = false
          let actions = self.inputHandler.handle(chunk)

          for action in actions {
            // When the boundary picker is open it owns all input — only its
            // navigation keys are honored; everything else is ignored.
            if self.pickerController.picker != nil {
              if self.pickerController.handleInput(
                action, transcriptState: &self.transcriptState,
                viewport: &self.viewport, flattenCache: &self.flattenCache)
              {
                continue
              }
            }
            switch action {
            case .bracketedPasteStart:
              self.inPaste = true
            case .bracketedPasteEnd:
              self.inPaste = false

            case .enter:
              if self.inPaste {
                if self.editMode == .edit { self.inputBuffer.append("\n") }
              } else if self.editMode == .read {
                self.logger.debug(
                  "chat.mode.to-edit",
                  metadata: ["source": "enter"])
                self.editMode = .edit
              } else {
                let text = self.inputBuffer
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed == "/fork" || trimmed == "/tldr" {
                  let kind: PickerSnapshot.Kind =
                    trimmed == "/fork" ? .fork : .tldr
                  // Picker open needs the doc snapshot for boundary
                  // computation; the doc is an actor so we await off the
                  // stdin tick and apply on MainActor.
                  self.inputBuffer = ""
                  let busy = self.modelBusy
                  let doc = self.document
                  Task { [weak self] in
                    let snap = await doc?.snapshot() ?? []
                    await MainActor.run { [weak self] in
                      guard let self else { return }
                      _ = self.pickerController.open(
                        kind: kind,
                        messages: snap,
                        modelBusy: busy,
                        transcriptState: &self.transcriptState,
                        viewport: &self.viewport,
                        flattenCache: &self.flattenCache)
                      self.renderWake?.requestRender()
                    }
                  }
                } else {
                  self.inputBuffer = ""
                  self.submitCoordinator.setModelBusy(self.modelBusy)
                  let effect = self.submitCoordinator.handleEnter(text: text)
                  shouldStop = self.applySubmitEffect(effect)
                }
              }

            case .ctrlC:
              if self.editMode == .edit {
                self.logger.debug(
                  "chat.mode.to-read",
                  metadata: ["source": "ctrl-c"])
                self.editMode = .read
              } else {
                let (effect, recallText) = self.submitCoordinator.handleCtrlC()
                if let recall = recallText {
                  self.inputBuffer = recall
                  self.editMode = .edit
                  self.renderWake?.requestRender()
                }
                shouldStop = self.applySubmitEffect(effect)
              }

            case .escape:
              if self.editMode == .edit {
                self.logger.debug(
                  "chat.mode.to-read",
                  metadata: ["source": "escape"])
                self.editMode = .read
              }

            case .ctrlD:
              self.logger.debug("chat.user.ctrl-d", metadata: ["action": "exit"])
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
              self.logger.debug(
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
            self.gate.complete(nil)
            return .stop
          }
        }

        let nowBusy = self.modelBusy
        self.submitCoordinator.setModelBusy(nowBusy)
        // TODO: allow a plugin/hook to decide drain-all vs drain-one here.
        let drained = self.submitCoordinator.handleModelTurnEnd()
        if !drained.isEmpty {
          for text in drained {
            self.logger.debug(
              "chat.queue.auto-flush",
              metadata: ["trigger": "busy-to-idle", "chars": "\(text.count)"])
          }
          self.queuedTrayTexts = self.submitCoordinator.queuedTexts
          for text in drained {
            self.gate.complete(text)
          }
        }

        self.drainIncomingEvents()

        slate.with { grid in
          let scrCols = grid.cols
          let scrRows = grid.rows

          // Picker just opened or moved: snap the viewport so the divider
          // sits roughly a third of the way down the transcript pane.
          // Needs scrCols (only known at frame time) to convert the
          // divider's logical-line index into a flattened-row target.
          if self.pickerController.picker != nil, self.pickerController.scrollDirty, scrCols > 0 {
            let prefixEnd = min(
              self.transcriptState.lines.count,
              self.pickerController.dividerLogicalLine &+ 1)
            let prefix = Array(self.transcriptState.lines.prefix(prefixEnd))
            let flatPrefix = TranscriptLayout.flattenedRows(
              from: prefix, width: scrCols)
            let dividerFlatRow = max(0, flatPrefix.count &- 1)
            let contentRows = SlateChatRenderer.transcriptContentRows(
              cols: scrCols, rows: scrRows,
              banner: self.banner, usage: self.transcriptState.usageHUD,
              inputLine: self.inputBuffer, waitingForLLM: self.modelBusy,
              queuedTrayText: self.queuedTrayTexts.first)
            let topOffset = max(0, contentRows / 3)
            self.viewport.queueScrollToRow(max(0, dividerFlatRow &- topOffset))
            self.pickerController.scrollDirty = false
          }

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
            picker: self.pickerController.picker,
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
            self.logger.debug(
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

    hostActive = false
    pickerController.cancelTask()
    coordinatorTask?.cancel()
    documentObserverTask?.cancel()
    self.gate.complete(nil)
    return exitInfo
  }

  // MARK: - Coordinator install / document identity

  /// Build the line stream for `self.gate` and start the host's one and
  /// only ChatCoordinator. The coordinator binds to `self.document` and
  /// lives for the host's whole lifetime — `/fork` and `/tldr` mutate
  /// the doc in place and the agent keeps running against the new
  /// identity automatically.
  private func installCoordinator() {
    guard let document = self.document else {
      self.logger.error(
        "chat.coordinator.init.fail",
        metadata: ["err": "document not ready before installCoordinator"])
      eventQueue.enqueue(.coordinatorFinished)
      return
    }
    let (lineStream, lineCont) = AsyncStream<String>.makeStream()
    self.gate.setStreamContinuation(lineCont)

    let coordinator: ChatCoordinator
    do {
      coordinator = try ChatCoordinator(
        configuration: configuration,
        logger: self.logger,
        enqueue: { [eventQueue] event in
          eventQueue.enqueue(event)
        },
        document: document,
        lines: lineStream
      )
    } catch {
      let scribeError = (error as? ScribeError) ?? .generic(String(describing: error))
      eventQueue.enqueue(.transcript(.lifecycle(.error(scribeError))))
      eventQueue.enqueue(.coordinatorFinished)
      self.logger.error(
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
  }

  /// Replay the doc's content into the transcript pane. Used for the
  /// initial render (where we already have the seed in hand) and after
  /// the document changes identity via `/fork` or `/tldr`.
  private func refreshTranscriptFromInitialSeed(_ messages: [ScribeMessage]) {
    transcriptState.lines = messages.isEmpty
      ? []
      : renderMessagesToTranscript(
        messages, theme: self.theme, renderer: self.markdownRenderer)
    flattenCache = TranscriptLayout.FlattenCache()
  }

  /// React to a ``ChangeSet/identityChanged`` event from the document.
  /// The doc has already swapped its own session id + directory + rope
  /// content; the host's job is to mirror that into UI state (transcript
  /// snapshot, banner, exit-hint) and reset per-turn scratch state. No
  /// coordinator restart — the coordinator + agent operate through the
  /// document and follow it automatically.
  private func handleIdentityChange(previous: UUID, sessionId newId: UUID, directory newDirectory: FilePath) {
    guard hostActive else {
      logger.notice("chat.identity.skip", metadata: ["reason": "host-inactive"])
      return
    }
    // Picker backup holds the *parent* session's pre-styled lines; once
    // identity changes they're meaningless.
    pickerController.clear()
    logger.notice(
      "chat.identity.swap",
      metadata: [
        "from": "\(previous.uuidString)",
        "to": "\(newId.uuidString)",
      ])

    exitInfo.forkedFromSessionId = previous
    exitInfo.forkedToSessionId = newId
    exitInfo.forkedToDirectory = newDirectory

    self.sessionDirectory = newDirectory
    self.sessionId = newId
    self.sessionCreatedAt = Date()
    self.modelBusy = false
    self.queuedTrayTexts = []
    self.submitCoordinator = SubmitCoordinator()

    // Refresh banner with the new session id (other fields unchanged).
    if let banner = self.banner {
      self.banner = BannerSnapshot(
        baseURL: banner.baseURL,
        model: banner.model,
        cwd: banner.cwd,
        scribeVersion: banner.scribeVersion,
        gitBranch: banner.gitBranch,
        sessionId: newId.uuidString)
    }

    // Re-render transcript from the doc's post-swap content. Doc snapshot
    // is async; resolve and apply on the MainActor.
    let doc = self.document
    Task { [weak self] in
      let snap = await doc?.snapshot() ?? []
      await MainActor.run { [weak self] in
        guard let self else { return }
        self.refreshTranscriptFromInitialSeed(snap)
        self.renderWake?.requestRender()
      }
    }
    renderWake?.requestRender()
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
    _ effect: SubmitEffect
  ) -> Bool {
    var state = HostSubmitState(queuedTrayTexts: queuedTrayTexts)
    let fx = HostSubmitState.apply(effect, to: &state)
    queuedTrayTexts = submitCoordinator.queuedTexts

    if let tag = fx.interruptLogTag {
      coordinator?.interrupt()
      logger.trace(
        "chat.interrupt-flag.\(tag)",
        metadata: ["coordinator": coordinator == nil ? "nil" : "live"])
    }
    if let text = fx.gateText {
      self.gate.complete(text)
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
