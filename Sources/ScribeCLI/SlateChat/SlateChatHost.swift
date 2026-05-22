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
  /// Messages used to seed the next coordinator. Initially the resumed
  /// history (or empty for a fresh session); replaced on hot-swap when the
  /// user forks or summarizes mid-session.
  private var currentSeed: [ScribeMessage]
  /// Session directory the active coordinator is reading from / writing to.
  /// Mutated on hot-swap.
  private var sessionDirectory: FilePath
  /// UUID of the active session. Mutated on hot-swap.
  private var sessionId: UUID
  /// Created-at timestamp of the active session. Mutated on hot-swap.
  private var sessionCreatedAt: Date
  /// Current input gate. Replaced on hot-swap so the new coordinator gets a
  /// fresh stream while the old coordinator's stream cleanly finishes.
  private var gate: UserLineGate = UserLineGate()

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
  /// `coordinatorFinished` events to swallow before treating one as a real
  /// shutdown signal. Incremented by `hotSwapToSession` each time it
  /// retires the previous coordinator so the trailing `.coordinatorFinished`
  /// the old coordinator emits doesn't tear down the live host.
  private var pendingFinishesToSwallow: Int = 0
  /// False once `run()` begins teardown — picker side-effects must not
  /// hot-swap or mutate UI after the host is winding down.
  private var hostActive: Bool = true
  private var exitInfo: ChatExitInfo = ChatExitInfo()
  /// Active boundary picker (driven by `/fork` and `/tldr`). When
  /// non-nil, the input area renders the picker and keystrokes are routed
  /// to boundary navigation instead of the normal submit pipeline.
  private var picker: PickerSnapshot?
  /// Running async work for a confirmed picker (e.g. summarize LLM call).
  /// `picker` is set to nil as soon as the user confirms; this task carries
  /// the side-effect work to completion.
  private var pickerActionTask: Task<Void, Never>?
  /// While the picker is open the host swaps `transcriptState.lines` for a
  /// styled preview (kept lines, divider, dimmed cut) and scrolls to the
  /// cut. This snapshot lets cancel restore both the transcript and the
  /// viewport position; confirm discards it because the hot-swap re-seeds.
  private var pickerBackup: (lines: [TLine], generation: Int, viewport: TranscriptViewport)?
  /// Disk messages displayed by the active picker — cached to avoid a
  /// re-read on every cursor move.
  private var pickerMessages: [ScribeMessage] = []
  /// Base (un-styled) transcript lines for `pickerMessages`, rebuilt on
  /// open. Restyled into `transcriptState.lines` on every cursor move.
  private var pickerBaseLines: [TLine] = []
  /// `messageStartLines` for `pickerBaseLines` (length `pickerMessages.count + 1`).
  /// Cursor index `cutAt` maps to base line `pickerBaseStarts[cutAt]`.
  private var pickerBaseStarts: [Int] = []
  /// Logical line index of the divider inside the *styled* picker
  /// transcript (the value the render closure flattens up to so it can
  /// snap the viewport on the divider).
  private var pickerDividerLogicalLine: Int = 0
  /// Set on open and on every cursor move; the render closure consumes it
  /// to queue a viewport scroll-to-row, then clears it.
  private var pickerScrollDirty: Bool = false
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
    self.currentSeed = resumeMessages
    self.sessionDirectory = sessionDirectory
    self.sessionId = sessionId
    self.sessionCreatedAt = sessionCreatedAt
    self.logger = logger
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

        // Initial transcript seed + banner setup, then start the first
        // coordinator. Hot-swap (after /fork or /tldr) re-runs only the
        // installCoordinator step against the new session.
        self.refreshTranscriptFromSeed()

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
            // navigation keys are honored; everything else is ignored so a
            // stray keystroke can't accidentally submit or scroll.
            if self.picker != nil {
              switch action {
              case .arrowUp:
                self.movePickerCursor(by: -1)
              case .arrowDown:
                self.movePickerCursor(by: +1)
              case .tab:
                self.togglePickerActive()
              case .enter:
                self.confirmPicker()
              case .escape, .ctrlC:
                self.cancelPicker()
              default:
                break
              }
              continue
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
                  self.inputBuffer = ""
                  self.openPicker(
                    kind: trimmed == "/fork" ? .fork : .tldr)
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
          if self.picker != nil, self.pickerScrollDirty, scrCols > 0 {
            let prefixEnd = min(
              self.transcriptState.lines.count,
              self.pickerDividerLogicalLine &+ 1)
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
            self.pickerScrollDirty = false
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
            picker: self.picker,
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
    pickerActionTask?.cancel()
    pickerActionTask = nil
    coordinatorTask?.cancel()
    self.gate.complete(nil)
    return exitInfo
  }

  // MARK: - Boundary picker

  /// Build a one-line preview describing the message at `index` so the
  /// picker can show what would be discarded (for `/fork`) or collapsed
  /// (for `/tldr`).
  private func pickerPreview(for messages: [ScribeMessage], at index: Int) -> String {
    if index >= messages.count { return "<end of session>" }
    let m = messages[index]
    let trimmed = m.content.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "\n", with: " ")
    let snippet: String = {
      if !trimmed.isEmpty { return String(trimmed.prefix(60)) }
      if let calls = m.toolCalls, let first = calls.first {
        return "[tool call: \(first.name)]"
      }
      return "<empty message>"
    }()
    return "\(m.role.rawValue): \(snippet)"
  }

  /// Compute the picker's default cursor positions.
  /// - `.fork`: most recent safe boundary (cut at "now"). End cursor is nil.
  /// - `.tldr`: start defaults to the boundary right after the most recent
  ///   user message (collapses the assistant's response to that turn); end
  ///   defaults to the last boundary (today's "summarize to the end"
  ///   behaviour). Falls back to a non-empty slice when no user message
  ///   exists.
  private func defaultCursor(
    kind: PickerSnapshot.Kind, messages: [ScribeMessage], boundaries: [Int]
  ) -> (start: Int, end: Int?) {
    guard !boundaries.isEmpty else { return (0, nil) }
    switch kind {
    case .fork:
      return (boundaries.count - 1, nil)
    case .tldr:
      let endIdx = boundaries.count - 1
      let startIdx: Int = {
        if let lastUser = messages.lastIndex(where: { $0.role == .user }),
          let idx = boundaries.firstIndex(of: lastUser + 1),
          idx < endIdx
        {
          return idx
        }
        return max(0, endIdx - 1)
      }()
      return (startIdx, endIdx)
    }
  }

  private func openPicker(kind: PickerSnapshot.Kind) {
    // Disk-persisted messages lag the live coordinator while a turn is
    // streaming, so opening the picker mid-turn would let the user pick
    // boundaries that don't reflect what's on screen. Make them wait.
    if modelBusy {
      logger.notice(
        "event=chat.picker.open.skip",
        metadata: ["kind": "\(kind)", "reason": "model-busy"])
      return
    }
    let messages: [ScribeMessage]
    do {
      messages = try ChatSessionStore.loadMessages(from: sessionDirectory)
    } catch {
      logger.warning(
        "event=chat.picker.open.fail",
        metadata: ["err": "\(String(describing: error))"])
      return
    }
    // Both `.fork` and `.tldr` cursors index into the same full list of
    // safe boundaries. `.tldr` enforces `start < end` at move time rather
    // than by pre-filtering — that keeps `messageCount` as a valid end-cut
    // (no tail) while still rejecting empty slices.
    let boundaries = messages.safeForkBoundaries()
    switch kind {
    case .fork:
      guard !boundaries.isEmpty else {
        logger.notice(
          "event=chat.picker.open.skip",
          metadata: ["kind": "fork", "reason": "no-safe-boundary"])
        return
      }
    case .tldr:
      guard boundaries.count >= 2 else {
        logger.notice(
          "event=chat.picker.open.skip",
          metadata: ["kind": "tldr", "reason": "needs-two-boundaries"])
        return
      }
    }
    let (startC, endC) = defaultCursor(
      kind: kind, messages: messages, boundaries: boundaries)
    let snap = PickerSnapshot(
      kind: kind,
      boundaries: boundaries,
      startCursor: startC,
      endCursor: endC,
      activeIsEnd: false,
      messageCount: messages.count,
      previewText: pickerPreview(for: messages, at: boundaries[startC])
    )

    // Render the disk-persisted history once so cursor moves only restyle
    // the cached base lines (no markdown re-render per arrow key).
    let rendered = renderMessagesToTranscriptWithStarts(
      messages, theme: theme, renderer: markdownRenderer)
    self.pickerMessages = messages
    self.pickerBaseLines = rendered.lines
    self.pickerBaseStarts = rendered.messageStartLines
    self.pickerBackup = (transcriptState.lines, transcriptState.generation, viewport)

    applyPickerView(snapshot: snap)
    logger.debug(
      "event=chat.picker.open",
      metadata: [
        "kind": "\(kind)",
        "boundaries": "\(boundaries.count)",
        "default_start": "\(boundaries[startC])",
        "default_end": "\(endC.map { "\(boundaries[$0])" } ?? "nil")",
      ])
  }

  private func movePickerCursor(by delta: Int) {
    guard var snap = picker else { return }
    let activeCurrent =
      snap.activeIsEnd ? (snap.endCursor ?? snap.startCursor) : snap.startCursor
    var newCursor = max(0, min(snap.boundaries.count - 1, activeCurrent + delta))
    // For `.tldr` keep the slice non-empty: start must stay strictly below
    // end. Block on collision (don't swap or push) — least surprising.
    if snap.kind == .tldr, let endIdx = snap.endCursor {
      if snap.activeIsEnd {
        newCursor = max(newCursor, snap.startCursor + 1)
      } else {
        newCursor = min(newCursor, endIdx - 1)
      }
      newCursor = max(0, min(snap.boundaries.count - 1, newCursor))
    }
    if newCursor == activeCurrent { return }
    if snap.activeIsEnd {
      snap.endCursor = newCursor
    } else {
      snap.startCursor = newCursor
    }
    snap.previewText = pickerPreview(
      for: pickerMessages, at: snap.boundaries[newCursor])
    applyPickerView(snapshot: snap)
  }

  /// Tab handler for `.tldr`: swap which cursor the arrow keys address.
  /// No-op for `.fork`.
  private func togglePickerActive() {
    guard var snap = picker, snap.kind == .tldr, snap.endCursor != nil else { return }
    snap.activeIsEnd.toggle()
    let activeCursor =
      snap.activeIsEnd ? (snap.endCursor ?? snap.startCursor) : snap.startCursor
    snap.previewText = pickerPreview(
      for: pickerMessages, at: snap.boundaries[activeCursor])
    applyPickerView(snapshot: snap)
  }

  private func cancelPicker() {
    guard picker != nil else { return }
    picker = nil
    restoreFromPickerBackup()
    logger.debug("event=chat.picker.cancel")
    renderWake?.requestRender()
  }

  /// Restyle the transcript with the current picker snapshot and request a
  /// scroll-to-divider on the next frame. For `.tldr` both cuts are placed;
  /// the viewport snaps to whichever divider is active.
  private func applyPickerView(snapshot: PickerSnapshot) {
    picker = snapshot
    let startBase =
      pickerBaseStarts.indices.contains(snapshot.startBoundary)
      ? pickerBaseStarts[snapshot.startBoundary]
      : pickerBaseLines.count
    let endBase: Int?
    if snapshot.kind == .tldr {
      let endBoundary = snapshot.endBoundary
      endBase =
        pickerBaseStarts.indices.contains(endBoundary)
        ? pickerBaseStarts[endBoundary]
        : pickerBaseLines.count
    } else {
      endBase = nil
    }
    let styled = buildPickerStyledLines(
      base: pickerBaseLines,
      startCutBase: startBase,
      endCutBase: endBase,
      kind: snapshot.kind,
      activeIsEnd: snapshot.activeIsEnd)
    transcriptState.lines = styled.lines
    transcriptState.generation &+= 1
    pickerDividerLogicalLine = styled.dividerLine
    pickerScrollDirty = true
    flattenCache = TranscriptLayout.FlattenCache()
    renderWake?.requestRender()
  }

  /// Restore the pre-picker transcript captured in `pickerBackup`. Called
  /// from cancel; confirm skips this because hot-swap re-seeds anyway.
  private func restoreFromPickerBackup() {
    guard let backup = pickerBackup else { return }
    transcriptState.lines = backup.lines
    transcriptState.generation = backup.generation &+ 1
    viewport = backup.viewport
    flattenCache = TranscriptLayout.FlattenCache()
    pickerBackup = nil
    pickerMessages = []
    pickerBaseLines = []
    pickerBaseStarts = []
    pickerScrollDirty = false
  }

  /// Build the picker-styled transcript.
  /// - `.fork`: `base[0..<startCutBase]` unchanged, then a blank + divider +
  ///   blank, then `base[startCutBase..<]` with every span recolored dim.
  /// - `.tldr`: `base[0..<startCutBase]` unchanged, start divider, dimmed
  ///   `base[startCutBase..<endCutBase]`, end divider, then
  ///   `base[endCutBase..<]` unchanged. The active divider (per `activeIsEnd`)
  ///   gets a brighter colour + bold; the inactive one stays dim.
  ///
  /// Returns the new lines and the logical line index of the *active*
  /// divider row so the viewport can snap to it.
  private func buildPickerStyledLines(
    base: [TLine],
    startCutBase: Int,
    endCutBase: Int?,
    kind: PickerSnapshot.Kind,
    activeIsEnd: Bool
  ) -> (lines: [TLine], dividerLine: Int) {
    let dimFG = theme.inputGutter
    switch kind {
    case .fork:
      let cut = max(0, min(startCutBase, base.count))
      let divFG = theme.errorFG
      let label = "──── /fork cut · everything below would be discarded ────"
      var out: [TLine] = []
      out.reserveCapacity(base.count &+ 3)
      out.append(contentsOf: base[0..<cut])
      out.append(TLine(spans: []))
      let dividerIndex = out.count
      out.append(
        TLine(spans: [
          StyledSpan(fg: divFG, bg: theme.background, bold: true, text: label)
        ]))
      out.append(TLine(spans: []))
      for line in base[cut..<base.count] {
        if line.spans.isEmpty {
          out.append(line)
          continue
        }
        let dimmed = line.spans.map { sp in
          StyledSpan(fg: dimFG, bg: sp.bg, bold: false, text: sp.text)
        }
        out.append(TLine(spans: dimmed))
      }
      return (out, dividerIndex)

    case .tldr:
      let endBase = endCutBase ?? base.count
      let startCut = max(0, min(startCutBase, base.count))
      let endCut = max(startCut, min(endBase, base.count))
      let activeFG = theme.warningFG
      let startFG = activeIsEnd ? dimFG : activeFG
      let endFG = activeIsEnd ? activeFG : dimFG
      let startLabel = "──── /tldr start · slice begins here ────"
      let endLabel = "──── /tldr end · slice ends here · tail preserved ────"
      var out: [TLine] = []
      out.reserveCapacity(base.count &+ 6)
      out.append(contentsOf: base[0..<startCut])
      out.append(TLine(spans: []))
      let startDividerIdx = out.count
      out.append(
        TLine(spans: [
          StyledSpan(
            fg: startFG, bg: theme.background, bold: !activeIsEnd,
            text: startLabel)
        ]))
      out.append(TLine(spans: []))
      for line in base[startCut..<endCut] {
        if line.spans.isEmpty {
          out.append(line)
          continue
        }
        let dimmed = line.spans.map { sp in
          StyledSpan(fg: dimFG, bg: sp.bg, bold: false, text: sp.text)
        }
        out.append(TLine(spans: dimmed))
      }
      out.append(TLine(spans: []))
      let endDividerIdx = out.count
      out.append(
        TLine(spans: [
          StyledSpan(
            fg: endFG, bg: theme.background, bold: activeIsEnd, text: endLabel)
        ]))
      out.append(TLine(spans: []))
      out.append(contentsOf: base[endCut..<base.count])
      let activeDivider = activeIsEnd ? endDividerIdx : startDividerIdx
      return (out, activeDivider)
    }
  }

  private func confirmPicker() {
    guard let snap = picker else { return }
    picker = nil
    pickerScrollDirty = false
    let kind = snap.kind
    let startCut = snap.startBoundary
    // For `.fork` this equals `startCut` and is unused; for `.tldr` it marks
    // the (exclusive) upper bound of the summarized slice.
    let endCut = snap.endBoundary
    let persistDirectory = sessionDirectory
    let configuration = self.configuration
    let logger = self.logger
    let parentSessionId = self.sessionId
    let eventQueue = self.eventQueue

    logger.notice(
      "event=chat.picker.confirm",
      metadata: [
        "kind": "\(kind)",
        "start_cut": "\(startCut)",
        "end_cut": kind == .tldr ? "\(endCut)" : "n/a",
      ])

    modelBusy = true
    renderWake?.requestRender()

    pickerActionTask?.cancel()
    pickerActionTask = Task { [weak self] in
      do {
        guard await MainActor.run(body: { self?.hostActive ?? false }) else { return }

        let newId = UUID()
        let result: ChatSessionStore.ForkResult
        switch kind {
        case .fork:
          result = try ChatSessionStore.forkSession(
            from: persistDirectory, cutAt: startCut, newSessionId: newId,
            scribeVersion: GitVersion.hash)
          logger.notice(
            "event=chat.fork.create",
            metadata: [
              "parent": "\(parentSessionId.uuidString)",
              "child": "\(result.sessionId.uuidString)",
              "cut_at": "\(result.cutAt)",
            ])
        case .tldr:
          let messages = try ChatSessionStore.loadMessages(from: persistDirectory)
          let slice = Array(messages[startCut..<endCut])
          let summary = try await SessionSummarizer.summarize(
            slice: slice, configuration: configuration, logger: logger)
          result = try ChatSessionStore.forkSession(
            from: persistDirectory, cutAt: startCut, newSessionId: newId,
            scribeVersion: GitVersion.hash)
          try ChatSessionStore.appendMessages(
            [ScribeMessage(role: .assistant, content: summary)],
            to: result.sessionDirectory)
          // Stitch the tail (messages after the summarized slice) so the
          // forked session ends on the same last message as the parent.
          // `safeForkBoundaries()` guarantees no tool round straddles
          // `endCut`, so tool_call ids in the tail don't reference the
          // collapsed slice.
          let tailCount = max(0, messages.count - endCut)
          if endCut < messages.count {
            let tail = Array(messages[endCut..<messages.count])
            try ChatSessionStore.appendMessages(tail, to: result.sessionDirectory)
          }
          logger.notice(
            "event=chat.tldr.create",
            metadata: [
              "parent": "\(parentSessionId.uuidString)",
              "child": "\(result.sessionId.uuidString)",
              "start_cut": "\(startCut)",
              "end_cut": "\(endCut)",
              "slice_messages": "\(slice.count)",
              "tail_messages": "\(tailCount)",
              "summary_chars": "\(summary.count)",
            ])
        }
        await MainActor.run { [weak self] in
          guard let self, self.hostActive else { return }
          self.hotSwapToSession(
            directory: result.sessionDirectory, sessionId: result.sessionId)
        }
      } catch {
        if Task.isCancelled { return }
        let se = (error as? ScribeError) ?? .generic(String(describing: error))
        logger.error(
          "event=chat.picker.action.fail err=\"\(se.errorDescription ?? String(describing: se))\""
        )
        eventQueue.enqueue(.transcript(.lifecycle(.error(se))))
        await MainActor.run { [weak self] in
          guard let self, self.hostActive else { return }
          // Drop the styled picker view so the user sees their live
          // transcript again instead of a stuck dim/divider state.
          self.restoreFromPickerBackup()
          self.modelBusy = false
          self.renderWake?.requestRender()
        }
      }
    }
  }

  // MARK: - Coordinator install / hot-swap

  /// Build the line stream for `self.gate` and start a fresh ChatCoordinator
  /// against `self.currentSeed` + `self.sessionDirectory`. Called once
  /// at startup and again after every hot-swap.
  private func installCoordinator() {
    let (lineStream, lineCont) = AsyncStream<String>.makeStream()
    self.gate.setStreamContinuation(lineCont)

    let coordinator: ChatCoordinator
    do {
      coordinator = try ChatCoordinator(
        configuration: configuration,
        systemPrompt: systemPrompt,
        resumeSnapshot: self.currentSeed,
        logger: self.logger,
        enqueue: { [eventQueue] event in
          eventQueue.enqueue(event)
        },
        persistDirectory: self.sessionDirectory,
        sessionId: self.sessionId,
        sessionCreatedAt: self.sessionCreatedAt,
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

  /// Replay `self.currentSeed` into the transcript pane (initial render and
  /// post-hot-swap redraw).
  private func refreshTranscriptFromSeed() {
    transcriptState.lines =
      currentSeed.isEmpty
      ? []
      : renderMessagesToTranscript(
        currentSeed, theme: self.theme, renderer: self.markdownRenderer)
    flattenCache = TranscriptLayout.FlattenCache()
  }

  /// Tear down the current coordinator and bring up a fresh one pointing at
  /// the forked session. Called after `/fork` or `/tldr` confirm.
  private func hotSwapToSession(directory newDirectory: FilePath, sessionId newId: UUID) {
    guard hostActive else {
      logger.notice("event=chat.hotswap.skip reason=host-inactive")
      return
    }
    // The picker backup holds the *parent* session's pre-styled lines; once
    // we hot-swap they're meaningless. Drop them along with the cached
    // picker base, but skip restoreFromPickerBackup — refreshTranscriptFromSeed
    // below replaces transcriptState entirely.
    pickerBackup = nil
    pickerMessages = []
    pickerBaseLines = []
    pickerBaseStarts = []
    pickerScrollDirty = false
    logger.notice(
      "event=chat.hotswap",
      metadata: [
        "from": "\(self.sessionId.uuidString)",
        "to": "\(newId.uuidString)",
      ])

    // Record where we ended up so the CLI's exit hint points at the right
    // session if the user types `exit` after this swap.
    exitInfo.forkedFromSessionId = self.sessionId
    exitInfo.forkedToSessionId = newId
    exitInfo.forkedToDirectory = newDirectory

    // Close the old gate so the old coordinator's stream finishes; the
    // coordinator's run() will wind down and emit `.coordinatorFinished`,
    // which we swallow once below so the host stays alive across the swap.
    self.gate.complete(nil)
    self.coordinatorTask?.cancel()
    self.pendingFinishesToSwallow += 1

    self.gate = UserLineGate()
    self.sessionDirectory = newDirectory
    self.sessionId = newId
    self.sessionCreatedAt = Date()
    self.currentSeed =
      (try? ChatSessionStore.loadMessages(from: newDirectory)) ?? []
    self.modelBusy = false
    self.queuedTrayTexts = []
    self.submitCoordinator = SubmitCoordinator()

    refreshTranscriptFromSeed()

    // Refresh banner with the new session id.
    if let banner = self.banner {
      self.banner = BannerSnapshot(
        baseURL: banner.baseURL,
        model: banner.model,
        cwd: banner.cwd,
        scribeVersion: banner.scribeVersion,
        gitBranch: banner.gitBranch,
        sessionId: newId.uuidString)
    }

    installCoordinator()
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
        if pendingFinishesToSwallow > 0 {
          pendingFinishesToSwallow -= 1
        } else {
          coordinatorFinished = true
        }
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
