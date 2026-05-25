import Foundation
import Logging
import ScribeCore
import SlateCore
import Synchronization
import SystemPackage

private final class UserLineGate: Sendable {
  private let state = Mutex(GateState())

  private struct GateState: Sendable {
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

struct ChatExitInfo: Sendable {

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

        cache.completedFlat = TranscriptLayout.flattenedRows(from: completed, width: width)
        cache.completedLogicalLines = completed.count
      } else if completed.count > cache.completedLogicalLines {

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
  private let harness: SessionHarness
  private let messageQueues: SessionMessageQueues
  private var sessionDirectory: FilePath
  private var sessionId: UUID
  private var sessionCreatedAt: Date
  private var gate: UserLineGate = UserLineGate()

  private var inputHandler = TerminalInputHandler()
  private var viewport = TranscriptViewport()

  private var editMode: EditMode = .edit

  private var transcriptState = TranscriptState()
  private var flattenCache = TranscriptLayout.FlattenCache()

  private var inputBuffer: String = ""
  private var inPaste: Bool = false
  private var modelBusy: Bool = false
  private var queueTrayDispatch: QueuedTraySnapshot.ActiveDispatch?
  private var queueBatchTotal: Int = 0
  private var steeringLineOutstanding: Bool = false
  private var coordinatorFinished: Bool = false

  private var hostActive: Bool = true
  private var exitInfo: ChatExitInfo = ChatExitInfo()

  private var pickerController = BoundaryPickerController()
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
    harness: SessionHarness,
    messageQueues: SessionMessageQueues,
    sessionDirectory: FilePath,
    sessionId: UUID,
    sessionCreatedAt: Date,
    logger: Logger
  ) {
    self.configuration = configuration
    self.harness = harness
    self.messageQueues = messageQueues
    self.sessionDirectory = sessionDirectory
    self.sessionId = sessionId
    self.sessionCreatedAt = sessionCreatedAt
    self.logger = logger

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
    var slate = try Slate()

    await slate.subscribe(
      prepare: { [self] wake in
        self.renderWake = wake
        self.contextWindow = self.configuration.contextWindow

        self.pickerController.applyEdit = { [weak self] op in
          guard let self else {
            throw ScribeError.generic("chat host gone before apply")
          }
          if let change = try await self.harness.applyEdit(op) {
            self.handleIdentityChange(change)
          }
        }
        self.pickerController.configuration = self.configuration

        Task { @MainActor in
          await self.refreshTranscriptFromDocument()

          let cwd = FilePath.currentDirectory.string
          self.banner = BannerSnapshot(
            baseURL: self.configuration.serverURL,
            model: self.configuration.agentModel,
            cwd: cwd,
            scribeVersion: GitVersion.hash,
            gitBranch: nil,
            sessionId: self.sessionId.uuidString)

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
        }
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
                  self.inputBuffer = ""
                  let busy = self.modelBusy
                  Task { @MainActor in
                    let snapshot = await self.harness.snapshot()
                    _ = self.pickerController.open(
                      kind: kind,
                      snapshot: snapshot,
                      modelBusy: busy,
                      transcriptState: &self.transcriptState,
                      viewport: &self.viewport,
                      flattenCache: &self.flattenCache)
                    self.renderWake?.requestRender()
                  }
                } else {
                  self.inputBuffer = ""
                  let effect = SubmitCoordinator.handleEnter(
                    text: text,
                    modelBusy: self.modelBusy,
                    steeringQueueCount: self.messageQueues.steeringCount(),
                    steeringLineOutstanding: self.steeringLineOutstanding)
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
                let effect = SubmitCoordinator.handleCtrlC(
                  steeringQueueCount: self.messageQueues.steeringCount(),
                  modelBusy: self.modelBusy)
                shouldStop = self.applySubmitEffect(effect)
                if case .recallSteeringToInput = effect {
                  if let recall = self.messageQueues.popSteeringForRecall() {
                    self.inputBuffer = recall
                    self.editMode = .edit
                    self.renderWake?.requestRender()
                  } else {
                    self.logger.warning(
                      "chat.queue.recall-missed",
                      metadata: ["reason": "steering-empty"])
                  }
                }
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
                  "steering_queue": "\(self.messageQueues.steeringCount())",
                  "follow_up_queue": "\(self.messageQueues.followUpCount())",
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
        let queuedTraySnapshot = self.makeQueuedTraySnapshot()

        self.drainIncomingEvents()

        slate.with { grid in
          let scrCols = grid.cols
          let scrRows = grid.rows

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
              queuedTraySnapshot: queuedTraySnapshot)
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
            queuedTraySnapshot: queuedTraySnapshot,
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
            queuedTraySnapshot: queuedTraySnapshot,
            picker: self.pickerController.picker,
            theme: .default)

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
                "queue_depth": "\(queuedTraySnapshot.pending.count)",
                "queue_batch": "\(queuedTraySnapshot.batchTotal)",
                "queue_chars": "\(queuedTraySnapshot.pending.first?.count ?? 0)",
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
    self.gate.complete(nil)
    return exitInfo
  }

  private func installCoordinator() {
    let (lineStream, lineCont) = AsyncStream<String>.makeStream()
    self.gate.setStreamContinuation(lineCont)

    let coordinator = ChatCoordinator(
      harness: harness,
      logger: self.logger,
      enqueue: { [eventQueue] event in
        eventQueue.enqueue(event)
      },
      lines: lineStream
    )
    self.coordinator = coordinator
    self.coordinatorTask = Task {
      await coordinator.run()
    }
  }

  private func refreshTranscriptFromDocument() async {
    let snapshot = await harness.snapshot()
    transcriptState.lines =
      snapshot.isEmpty
      ? []
      : renderMessagesToTranscript(
        snapshot.messages, theme: self.theme, renderer: self.markdownRenderer)
    flattenCache = TranscriptLayout.FlattenCache()
  }

  private func handleIdentityChange(_ change: SessionIdentityChange) {
    handleIdentityChange(
      previous: change.previousSessionId,
      sessionId: change.newSessionId,
      directory: change.newDirectory)
  }

  private func handleIdentityChange(previous: UUID, sessionId newId: UUID, directory newDirectory: FilePath) {
    guard hostActive else {
      logger.notice("chat.identity.skip", metadata: ["reason": "host-inactive"])
      return
    }

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
    queueTrayDispatch = nil
    queueBatchTotal = 0
    steeringLineOutstanding = false
    messageQueues.clearAll()

    if let banner = self.banner {
      self.banner = BannerSnapshot(
        baseURL: banner.baseURL,
        model: banner.model,
        cwd: banner.cwd,
        scribeVersion: banner.scribeVersion,
        gitBranch: banner.gitBranch,
        sessionId: newId.uuidString)
    }

    Task { @MainActor in
      await self.refreshTranscriptFromDocument()
      self.renderWake?.requestRender()
    }
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
        if let dispatch = queueTrayDispatch,
          text.trimmingCharacters(in: .whitespacesAndNewlines)
            == dispatch.text.trimmingCharacters(in: .whitespacesAndNewlines)
        {
          queueTrayDispatch = nil
          steeringLineOutstanding = false
        }
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

  private func makeQueuedTraySnapshot() -> QueuedTraySnapshot {
    let pending = messageQueues.steeringPreviewTexts()
    let inFlight = queueTrayDispatch == nil ? 0 : 1
    queueBatchTotal = max(queueBatchTotal, pending.count + inFlight)
    if pending.isEmpty, queueTrayDispatch == nil {
      queueBatchTotal = 0
    }
    let batchTotal = max(queueBatchTotal, pending.count + inFlight)
    return QueuedTraySnapshot(
      pending: pending,
      activeDispatch: queueTrayDispatch,
      batchTotal: batchTotal,
      modelBusy: modelBusy)
  }

  private func recordSteeringPopDispatch(poppedText: String) {
    let pendingBeforePop = messageQueues.steeringCount()
    let index = max(1, queueBatchTotal - pendingBeforePop + 1)
    queueBatchTotal = max(queueBatchTotal, pendingBeforePop + index - 1)
    queueTrayDispatch = QueuedTraySnapshot.ActiveDispatch(
      index: index,
      text: poppedText)
  }

  private func applySubmitEffect(
    _ effect: SubmitEffect
  ) -> Bool {
    let fx = HostSubmitSideEffects.from(effect)

    if let text = fx.enqueueSteering {
      if messageQueues.enqueueSteering(text: text) {
        queueBatchTotal = max(queueBatchTotal, messageQueues.steeringCount())
        logger.debug(
          "chat.queue.steer",
          metadata: ["chars": "\(text.count)", "depth": "\(messageQueues.steeringCount())"])
      } else {
        logger.debug(
          "chat.queue.steer-skipped",
          metadata: ["reason": "blank-after-trim"])
      }
    }
    if let text = fx.enqueueFollowUp {
      if messageQueues.enqueueFollowUp(text: text) {
        logger.debug(
          "chat.queue.follow-up",
          metadata: ["chars": "\(text.count)", "depth": "\(messageQueues.followUpCount())"])
      } else {
        logger.debug(
          "chat.queue.follow-up-skipped",
          metadata: ["reason": "blank-after-trim"])
      }
    }

    if let tag = fx.interruptLogTag {
      coordinator?.interrupt()
      logger.trace(
        "chat.interrupt-flag.\(tag)",
        metadata: ["coordinator": coordinator == nil ? "nil" : "live"])
    }

    if fx.popSteeringToGate {
      if let text = messageQueues.popSteeringForRecall(), !text.isEmpty {
        recordSteeringPopDispatch(poppedText: text)
        steeringLineOutstanding = true
        gate.complete(text)
      } else {
        logger.warning(
          "chat.queue.pop-missed",
          metadata: ["reason": "steering-empty", "effect": "\(effect)"])
      }
    } else if let text = fx.gateText, !text.isEmpty {
      gate.complete(text)
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
