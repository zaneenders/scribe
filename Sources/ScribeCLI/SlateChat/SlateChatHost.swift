import Foundation
import Logging
import ScribeCore
import ScribeLLM
import SlateCore
import Synchronization
import _RopeModule

// MARK: - User input

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

/// Cooperative abort for Ctrl+C during an assistant/tool round without cancelling the long-lived coordinator task.
private final class ModelTurnInterruptFlag: Sendable {
  private let lock = Mutex(false)

  func clear() {
    lock.withLock { $0 = false }
  }

  func request() {
    lock.withLock { $0 = true }
  }

  func peek() -> Bool {
    lock.withLock { $0 }
  }
}

/// Incremental word-wrap flatten of completed transcript lines (streaming only re-wraps the open tail).
private struct TranscriptFlattenCache {
  var wrapWidth: Int = -1
  var completedLogicalLines: Int = 0
  var completedFlat: [TLine] = []
  var lastGeneration: Int = -1
}

// MARK: - Host

/// The Slate chat host manages all user input routing — `Enter`, `Ctrl+C`, and the
/// queued-tray strip — relative to the agent's busy/idle state.
///
/// ## Edit / Read mode
///
/// The input box has two modes toggled with `Escape` / `i` / `Enter`:
///
/// ```
/// ┌──────┐  Escape / Ctrl+C   ┌──────┐
/// │ edit │ ──────────────────→ │ read │
/// │      │ ←────────────────── │      │
/// └──┬───┘    i / Enter        └──┬───┘
///    │ Enter (submit)             │ Ctrl+C (ladder)
///    ▼                            ▼
///   send                        interrupt / exit
/// ```
///
/// ### Key bindings
///
/// | Key | Edit mode | Read mode |
/// |-----|-----------|-----------|
/// | Printable chars | Insert at cursor | `i` enters edit mode; others ignored |
/// | `Backspace` | Delete char before cursor | — |
/// | `Enter` | Submit message (with queue logic) | Enter edit mode |
/// | `Shift+Enter` | Insert newline at cursor | — |
/// | `Escape` | Switch to read mode | — |
/// | `Ctrl+C` | Switch to read mode | Ladder: recall queue → interrupt → exit |
/// | `Ctrl+D` | Quit chat | Quit chat |
/// | `←` / `→` | Move cursor left / right | — |
/// | `↑` / `↓` | — (TODO: visual-line movement) | Scroll transcript one row |
/// | `Home` | Move cursor to start of buffer | Jump to top of transcript |
/// | `End` | Move cursor to end of buffer | Jump to live tail |
/// | `Page Up` / `Page Down` | — | Scroll transcript one page |
/// | `Tab` | Insert 4 spaces (paste only) | — |
///
/// ### Submit / queue logic (edit mode only)
///
/// | Situation | Result |
/// |---|---|
/// | Agent **idle** + Enter (non-empty buffer) | Message sent **immediately**. |
/// | Agent **busy** + Enter (non-empty buffer) | Buffer text goes into the **queued tray**. |
/// | Agent busy + queue exists + Enter on **empty** buffer | **Interrupts** the in-flight turn and sends the queued message. |
/// | Agent busy + queue exists + types more + Enter | New text **replaces** the queued message. |
/// | Agent finishes a turn with queue non-empty | Queued message **auto-flushes** on the busy → idle transition. |
///
/// ### Ctrl+C ladder (read mode only)
///
/// When a queued message exists, three taps of Ctrl+C walk through three states:
///
/// 1. **Recall** — first press pulls the queued message back into the input box
///    (switching to edit mode). The agent keeps running.
/// 2. **Interrupt** — second press (queue empty, agent still busy) interrupts
///    the in-flight model turn.
/// 3. **Exit** — third press (queue empty, agent idle) exits the chat.
///
/// If the agent is already idle when you start pressing, step 2 is skipped: a
/// single Ctrl+C with no queue exits.
///
/// ## Key design notes
///
/// - **Single-slot queue.** Submitting again while busy replaces the previous queued
///   message rather than appending; recall it with Ctrl+C if you want to edit
///   instead of overwrite.
/// - **Scrollback recording is deferred to pickup.** ``readUserLine`` is wrapped so
///   the orange `you:` block is appended to scrollback exactly when the coordinator
///   consumes the line. This gives the right ordering for the interrupt-and-send
///   case: `previous turn → (interrupted) → you: queued message → new response`.
/// - **Tray geometry.** The tray sits between the transcript and the input strip,
///   shares the input strip background, indents continuation rows under an 8-space
///   gutter (matching the width of `queued: `), and is hard-capped at 4 rows with
///   trailing `…` truncation so a long queued paste cannot push the transcript off
///   screen.
/// - **Busy → idle transition** is detected in the render callback by comparing
///   `sink.modelTurnBusy()` against the previous render's snapshot
///   (`lastObservedModelBusy`); the auto-flush fires exactly once per transition.
///   `markModelTurnRunning(false)` also schedules a deferred 50 ms follow-up
///   `requestRender()` so the throttled external-wake stream cannot drop the
///   trailing render that paints the new idle state.
@MainActor
internal final class SlateChatHost {

  private let configuration: AgentConfig
  private let systemPrompt: String
  private let resumeArchive: ChatSessionArchive?
  private let sessionPersistenceURL: URL
  private let sessionId: UUID
  private let sessionCreatedAt: Date
  private var buffer = BigString()
  private var cursor: BigString.Index
  private var mode = EditMode.edit
  /// Index into the flattened transcript of the top row of the transcript viewport (used when ``followingLiveTranscript`` is false).
  private var transcriptFirstVisibleRow: Int = 0
  /// When true, the viewport follows the live tail (new tokens stay at the bottom). When false, ``transcriptFirstVisibleRow`` is fixed so streaming does not move the view.
  private var followingLiveTranscript: Bool = true
  private var flattenCache = TranscriptFlattenCache()
  /// stdin key decoder (handles UTF-8, CSI, bracketed paste) — provided by slate.
  private var keyDecoder = TerminalKeyDecoder()
  /// True while inside a bracketed paste region (paste newlines stay literal instead of submitting).
  private var inPaste = false
  private var renderWake: ExternalWake?
  private var llmWaitAnimationFrame: Int = 0
  private var spinnerTask: Task<Void, Never>?
  private var coordinatorTask: Task<Void, Never>?
  private let modelInterruptFlag = ModelTurnInterruptFlag()
  /// Holds a user submission that arrived while the agent was busy. The text lives in the queued
  /// tray UI strip above the input; it is delivered to the coordinator when the user explicitly
  /// hits Enter again (interrupting the agent), recalls it with Ctrl+C, or when the current model
  /// turn finishes naturally.
  private var queuedSubmission: String? = nil
  /// Previous-render snapshot of `sink.modelTurnBusy()`, used to detect busy → idle transitions
  /// in `onEvent` and auto-flush a queued submission to the coordinator at that moment.
  private var lastObservedModelBusy: Bool = false
  /// Per-session logger threaded in from `Chat.run`; writes to `scribe-{uuid}.log`.
  private let log: Logger
  private let tools: [any ScribeTool]

  init(
    configuration: AgentConfig,
    systemPrompt: String,
    resumeArchive: ChatSessionArchive?,
    sessionPersistenceURL: URL,
    sessionId: UUID,
    sessionCreatedAt: Date,
    log: Logger,
    tools: [any ScribeTool]
  ) {
    self.configuration = configuration
    self.systemPrompt = systemPrompt
    self.resumeArchive = resumeArchive
    self.sessionPersistenceURL = sessionPersistenceURL
    self.sessionId = sessionId
    self.sessionCreatedAt = sessionCreatedAt
    self.log = log
    self.tools = tools
    self.cursor = buffer.startIndex
  }

  deinit {
    spinnerTask?.cancel()
  }

  /// The input text as a plain String (derived from the BigString buffer).
  private var inputText: String { String(buffer) }

  func run() async throws {
    var slate = try Slate()
    let sink = SlateTranscriptSink(theme: .default)
    let gate = UserLineGate()

    // Bracketed paste is now handled by slate itself (CSI.bracketedPasteOn/Off emitted
    // during bootstrap/teardown) and TerminalKeyDecoder already parses paste markers.

    // External wakes (every SSE chunk, every persist, every emitUsage) are coalesced at the
    // pump's default ~60 fps — i.e. at most one render per ~16 ms regardless of how busy the
    // streaming side is. Coupled with the async tty writer in `slate` (frames are submitted
    // to a background task instead of blocking the main actor on `write(2)`), this keeps the
    // main actor responsive to stdin even during heavy reasoning streams.
    //
    // The throttle pipeline can elide the *trailing* wake at the end of a fast burst — so
    // `markModelTurnRunning(false)` schedules a deferred follow-up render (see
    // ``SlateTranscriptSink/markModelTurnRunning``) that fires ~50 ms later, guaranteeing the
    // UI catches up to the new idle state instead of leaving the spinner hot until the next
    // key/resize.
    await slate.start(
      prepare: { [self] wake in
        sink.installWake(wake)
        sink.setContextWindow(self.configuration.contextWindow)
        self.renderWake = wake
        let resumeSnapshot = self.resumeArchive
        if let resumed = resumeSnapshot {
          TranscriptReplay.replay(
            messages: resumed.messages,
            onEvent: { sink.emit($0) },
            recordUserSubmission: { sink.recordUserSubmission(trimmedVisible: $0) }
          )
          self.flattenCache = TranscriptFlattenCache()
        }

        let persistURL = self.sessionPersistenceURL
        let cid = self.sessionId
        let created = self.sessionCreatedAt
        let modelSnapshot = self.configuration.agentModel
        let baseSnapshot = self.configuration.serverURL
        let persistLog = self.log
        let persist = ChatSessionStore.makePersistCallback(
          sessionId: cid,
          createdAt: created,
          model: modelSnapshot,
          baseURL: baseSnapshot,
          persistURL: persistURL,
          logger: persistLog
        )

        let cwd = FileManager.default.currentDirectoryPath
        sink.setBanner(baseURL: self.configuration.serverURL, model: self.configuration.agentModel, cwd: cwd)

        let interruptFlag = self.modelInterruptFlag
        let sessionLog = self.log
        self.coordinatorTask = Task {
          [
            configuration, systemPrompt, sink, gate, resumeSnapshot, persist, interruptFlag, sessionLog,
            tools
          ] in
          defer { sink.markCoordinatorFinished() }
          do {
            let agent = ScribeAgent(
              configuration: configuration,
              systemPrompt: systemPrompt,
              tools: tools
            )
            try await agent.runInteractive(
              onEvent: { event in sink.emit(event) },
              readUserLine: {
                // Record the submission in scrollback exactly when the coordinator picks it up,
                // so messages held in the queued-tray (during a busy turn) appear in scrollback
                // only at the moment they're dispatched—not while they sit in the tray.
                guard let line = await gate.nextLine() else { return nil }
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                  sink.recordUserSubmission(trimmedVisible: trimmed)
                }
                return line
              },
              initialConversation: resumeSnapshot?.messages,
              onConversationPersist: persist,
              prepareModelTurnStart: { interruptFlag.clear() },
              shouldAbortTurn: { interruptFlag.peek() },
              log: sessionLog
            )
          } catch {
            let scribeError = (error as? ScribeError) ?? .generic(String(describing: error))
            sink.emit(.harnessError(scribeError))
            sessionLog.error(
              """
              event=chat.coordinator.fail \
              err="\(scribeError.errorDescription ?? String(describing: scribeError))"
              """
            )
          }
        }
        self.spinnerTask?.cancel()
        self.spinnerTask = Task { [weak self] in
          while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(90))
            guard let self else { return }
            guard sink.modelTurnBusy() else { continue }
            self.llmWaitAnimationFrame &+= 1
            self.renderWake?.requestRender()
          }
        }
        wake.requestRender()
      },
      externalCoalesceMaxFramesPerSecond: 60,
      onEvent: { slate, event in
        switch event {
        case .resize:
          slate.refreshWindowSize()
        case .external:
          break
        case .stdinBytes(let chunk):
          if sink.coordinatorFinished() { return .stop }
          if chunk.isEmpty {
            Task { await gate.complete(nil) }
            return .stop
          }
          var shouldStop = false
          self.keyDecoder.decode(chunk) { key in
            switch (self.mode, key) {

            // ── Always-available keys ──
            case (_, .ctrl(4)):  // Ctrl+D — quit from either mode
              self.log.debug(
                "event=chat.user.ctrl-d action=exit mode=\(self.mode == .edit ? "edit" : "read")")
              shouldStop = true

            case (_, .bracketedPasteStart):
              self.inPaste = true

            case (_, .bracketedPasteEnd):
              self.inPaste = false

            // ── Edit mode ──
            case (.edit, .character(let ch)):
              self.buffer.insert(contentsOf: String(ch), at: self.cursor)
              self.cursor = self.buffer.index(after: self.cursor)

            case (.edit, .backspace):
              if !self.inPaste, self.cursor > self.buffer.startIndex {
                let prev = self.buffer.index(before: self.cursor)
                self.buffer.removeSubrange(prev..<self.cursor)
                self.cursor = prev
              }

            case (.edit, .shiftEnter):
              self.buffer.insert(contentsOf: "\n", at: self.cursor)
              self.cursor = self.buffer.index(after: self.cursor)
              self.log.debug(
                """
                event=chat.user.input.newline \
                source=shift-enter \
                buffer_chars=\(self.buffer.count) \
                has_queue=\(self.queuedSubmission != nil)
                """)

            case (.edit, .enter):
              if self.inPaste {
                self.buffer.insert(contentsOf: "\n", at: self.cursor)
                self.cursor = self.buffer.index(after: self.cursor)
              } else {
                self.submitUserLine(sink: sink, gate: gate)
              }

            case (.edit, .tab):
              if self.inPaste {
                self.buffer.insert(contentsOf: "    ", at: self.cursor)
                self.cursor = self.buffer.index(after: self.cursor)
              }

            case (.edit, .escape):
              self.log.debug("event=chat.mode.to-read source=escape")
              self.mode = .read

            case (.edit, .ctrl(3)):  // Ctrl+C → switch to read mode
              self.log.debug("event=chat.mode.to-read source=ctrl-c")
              self.mode = .read

            // Cursor movement in edit mode
            case (.edit, .arrowLeft):
              if self.cursor > self.buffer.startIndex {
                self.cursor = self.buffer.index(before: self.cursor)
              }
            case (.edit, .arrowRight):
              if self.cursor < self.buffer.endIndex {
                self.cursor = self.buffer.index(after: self.cursor)
              }
            case (.edit, .arrowUp):
              // TODO: visual-line-aware vertical cursor movement (Step 3)
              break
            case (.edit, .arrowDown):
              // TODO: visual-line-aware vertical cursor movement (Step 3)
              break
            case (.edit, .home):
              self.cursor = self.buffer.startIndex
            case (.edit, .end):
              self.cursor = self.buffer.endIndex

            // ── Read mode ──
            case (.read, .enter):
              self.log.debug("event=chat.mode.to-edit source=enter")
              self.mode = .edit

            case (.read, .character(let ch)):
              // Only 'i' enters edit mode; other chars are ignored in read mode
              if ch == "i" && !self.inPaste {
                self.log.debug("event=chat.mode.to-edit source=i")
                self.mode = .edit
              }

            case (.read, .ctrl(3)):
              // Ctrl+C ladder in read mode
              let busy = sink.modelTurnBusy()
              if let queued = self.queuedSubmission {
                // 1. Pull queued message back into input buffer
                self.log.debug(
                  """
                  event=chat.user.ctrl-c \
                  action=recall-queue \
                  queue_chars=\(queued.count) \
                  model_busy=\(busy)
                  """)
                self.queuedSubmission = nil
                sink.setQueuedTrayText(nil)
                self.buffer = BigString()
                self.buffer.insert(contentsOf: queued, at: self.buffer.startIndex)
                self.cursor = self.buffer.endIndex
                self.mode = .edit
                self.renderWake?.requestRender()
              } else if busy {
                // 2. Interrupt in-flight turn
                self.log.debug(
                  """
                  event=chat.user.ctrl-c \
                  action=interrupt-agent \
                  model_busy=true
                  """)
                self.modelInterruptFlag.request()
                self.renderWake?.requestRender()
              } else {
                // 3. Exit chat
                self.log.debug(
                  """
                  event=chat.user.ctrl-c \
                  action=exit \
                  model_busy=false
                  """)
                shouldStop = true
              }

            // Transcript scroll-back (read mode only)
            case (.read, .arrowUp):
              self.applyTranscriptScroll(delta: -1, sink: sink, slate: slate)
            case (.read, .arrowDown):
              self.applyTranscriptScroll(delta: +1, sink: sink, slate: slate)
            case (.read, .pageUp), (.read, .ctrl(2)):
              self.applyTranscriptScrollPage(up: true, sink: sink, slate: slate)
            case (.read, .pageDown), (.read, .ctrl(6)):
              self.applyTranscriptScrollPage(up: false, sink: sink, slate: slate)
            case (.read, .home):
              self.followingLiveTranscript = false
              self.transcriptFirstVisibleRow = 0
              self.renderWake?.requestRender()
            case (.read, .end):
              self.followingLiveTranscript = true
              self.renderWake?.requestRender()

            default:
              break
            }
          }
          if shouldStop {
            Task { await gate.complete(nil) }
            return .stop
          }
        }

        // Auto-flush a queued tray message when the agent finishes a turn naturally
        let nowBusy = sink.modelTurnBusy()
        if !nowBusy, self.lastObservedModelBusy, let queued = self.queuedSubmission {
          self.log.debug(
            """
            event=chat.queue.auto-flush \
            trigger=busy-to-idle \
            chars=\(queued.count)
            """)
          self.queuedSubmission = nil
          sink.setQueuedTrayText(nil)
          Task { await gate.complete(queued) }
        }
        self.lastObservedModelBusy = nowBusy

        let prepareStart = Date()
        let flatTranscript = self.syncFlattenedTranscript(sink: sink, slate: slate)
        let queuedTrayText = sink.queuedTrayTextSnapshot()
        let contentRows = SlateChatRenderer.transcriptContentRows(
          cols: slate.cols,
          rows: slate.rows,
          banner: sink.bannerSnapshot(),
          usage: sink.usageHUDSnapshot(),
          inputLine: self.inputText,
          waitingForLLM: sink.modelTurnBusy(),
          queuedTrayText: queuedTrayText
        )
        let maxTailStart = max(0, flatTranscript.count &- contentRows)
        if self.followingLiveTranscript {
          self.transcriptFirstVisibleRow = maxTailStart
        } else {
          self.transcriptFirstVisibleRow = min(self.transcriptFirstVisibleRow, maxTailStart)
        }
        let transcriptTailStart = self.transcriptFirstVisibleRow
        let prepareMs = Int(Date().timeIntervalSince(prepareStart) * 1000)
        let submitStart = Date()
        slate.enscribe(
          grid: SlateChatRenderer.makeGrid(
            cols: slate.cols,
            rows: slate.rows,
            flattenedTranscript: flatTranscript,
            transcriptTailStart: transcriptTailStart,
            banner: sink.bannerSnapshot(),
            usage: sink.usageHUDSnapshot(),
            inputLine: self.inputText,
            inputMode: self.mode,
            llmWaitAnimationFrame: self.llmWaitAnimationFrame,
            waitingForLLM: sink.modelTurnBusy(),
            queuedTrayText: queuedTrayText,
            theme: .default))
        let submitMs = Int(Date().timeIntervalSince(submitStart) * 1000)
        let totalMs = prepareMs &+ submitMs
        if totalMs >= 50 {
          self.log.debug(
            """
            event=chat.render.slow \
            elapsed_ms=\(totalMs) \
            prepare_ms=\(prepareMs) \
            submit_ms=\(submitMs) \
            flat_rows=\(flatTranscript.count) \
            cols=\(slate.cols) \
            rows=\(slate.rows) \
            model_busy=\(nowBusy) \
            queue_chars=\(self.queuedSubmission?.count ?? 0) \
            buffer_chars=\(self.buffer.count)
            """)
        }
        return sink.coordinatorFinished() ? .stop : .continue
      })

    spinnerTask?.cancel()
    spinnerTask = nil
    renderWake = nil

    coordinatorTask?.cancel()
    await gate.complete(nil)
  }

  /// Handles Enter in the input box:
  /// - **Empty buffer + no queued tray message** → no-op.
  /// - **Empty buffer + queued tray message** → interrupt the in-flight model turn (if any)
  ///   and dispatch the queued message to the coordinator.
  /// - **Non-empty buffer + agent idle** → dispatch immediately.
  /// - **Non-empty buffer + agent busy** → place into queued tray.
  private func submitUserLine(sink: SlateTranscriptSink, gate: UserLineGate) {
    followingLiveTranscript = true
    transcriptFirstVisibleRow = 0
    let submit = inputText
    buffer = BigString()
    cursor = buffer.startIndex
    let trimmed = submit.trimmingCharacters(in: .whitespacesAndNewlines)
    let busy = sink.modelTurnBusy()
    let newlines = submit.reduce(0) { $0 + ($1 == "\n" ? 1 : 0) }

    if trimmed.isEmpty {
      guard let queued = queuedSubmission else {
        log.debug(
          """
          event=chat.user.submit \
          kind=noop \
          reason=empty-buffer-no-queue \
          model_busy=\(busy)
          """)
        return
      }
      let queuedNewlines = queued.reduce(0) { $0 + ($1 == "\n" ? 1 : 0) }
      log.debug(
        """
        event=chat.user.submit \
        kind=interrupt-and-send \
        chars=\(queued.count) \
        newlines=\(queuedNewlines) \
        model_busy=\(busy)
        """)
      queuedSubmission = nil
      sink.setQueuedTrayText(nil)
      if busy {
        modelInterruptFlag.request()
      }
      Task { await gate.complete(queued) }
      renderWake?.requestRender()
      return
    }

    if busy {
      let replacing = queuedSubmission != nil
      log.debug(
        """
        event=chat.user.submit \
        kind=queue \
        chars=\(submit.count) \
        newlines=\(newlines) \
        replacing=\(replacing) \
        model_busy=true
        """)
      queuedSubmission = submit
      sink.setQueuedTrayText(submit)
      renderWake?.requestRender()
    } else {
      log.debug(
        """
        event=chat.user.submit \
        kind=immediate \
        chars=\(submit.count) \
        newlines=\(newlines) \
        model_busy=false
        """)
      Task { await gate.complete(submit) }
    }
  }

  // MARK: - Transcript viewport

  /// Recomputes word-wrapped transcript rows, reusing flatten work for completed lines across streaming frames.
  private func syncFlattenedTranscript(sink: SlateTranscriptSink, slate: borrowing Slate) -> [TLine] {
    let (completed, open, generation) = sink.snapshotTranscriptForLayout()
    let width = slate.cols

    if width != flattenCache.wrapWidth || generation != flattenCache.lastGeneration {
      flattenCache = TranscriptFlattenCache()
      flattenCache.wrapWidth = width
      flattenCache.lastGeneration = generation
      flattenCache.completedFlat = TranscriptLayout.flattenedRows(from: completed, width: width)
      flattenCache.completedLogicalLines = completed.count
    } else if completed.count < flattenCache.completedLogicalLines {
      flattenCache.completedFlat = TranscriptLayout.flattenedRows(from: completed, width: width)
      flattenCache.completedLogicalLines = completed.count
    } else if completed.count > flattenCache.completedLogicalLines {
      let start = flattenCache.completedLogicalLines
      if start < completed.count {
        let newSlice = completed[start...]
        flattenCache.completedFlat.append(
          contentsOf: TranscriptLayout.flattenedRows(from: Array(newSlice), width: width))
      }
      flattenCache.completedLogicalLines = completed.count
    }

    if let open {
      return flattenCache.completedFlat
        + TranscriptLayout.flattenedRows(from: [open], width: width)
    }
    return flattenCache.completedFlat
  }

  /// Move transcript viewport by `delta` lines (negative = up/older, positive = down/newer).
  private func applyTranscriptScroll(
    delta: Int, sink: SlateTranscriptSink, slate: borrowing Slate
  ) {
    let flat = syncFlattenedTranscript(sink: sink, slate: slate)
    let contentRows = SlateChatRenderer.transcriptContentRows(
      cols: slate.cols, rows: slate.rows,
      banner: sink.bannerSnapshot(), usage: sink.usageHUDSnapshot(),
      inputLine: inputText, waitingForLLM: sink.modelTurnBusy(),
      queuedTrayText: sink.queuedTrayTextSnapshot())
    let maxTailStart = max(0, flat.count &- contentRows)

    if delta < 0 {
      let wasFollowing = followingLiveTranscript
      followingLiveTranscript = false
      if wasFollowing {
        transcriptFirstVisibleRow = max(0, maxTailStart &+ delta)
      } else {
        transcriptFirstVisibleRow = max(0, transcriptFirstVisibleRow &+ delta)
      }
    } else {
      transcriptFirstVisibleRow = min(transcriptFirstVisibleRow &+ delta, maxTailStart)
      if transcriptFirstVisibleRow >= maxTailStart {
        followingLiveTranscript = true
      }
    }
    renderWake?.requestRender()
  }

  /// Move transcript viewport by one page (up or down).
  private func applyTranscriptScrollPage(
    up: Bool, sink: SlateTranscriptSink, slate: borrowing Slate
  ) {
    let contentRows = SlateChatRenderer.transcriptContentRows(
      cols: slate.cols, rows: slate.rows,
      banner: sink.bannerSnapshot(), usage: sink.usageHUDSnapshot(),
      inputLine: inputText, waitingForLLM: sink.modelTurnBusy(),
      queuedTrayText: sink.queuedTrayTextSnapshot())
    let page = max(1, contentRows)
    let delta = up ? -page : page
    applyTranscriptScroll(delta: delta, sink: sink, slate: slate)
  }
}
