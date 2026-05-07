import Foundation
import Logging
import ScribeCore
import ScribeLLM
import SlateCore
import Synchronization

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

  func logState(_ logger: Logger, tag: String) {
    let val = peek()
    logger.trace(
      """
      event=chat.interrupt-flag.\(tag) \
      value=\(val)
      """)
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
/// ## Behavior table
///
/// | Situation | Result |
/// |---|---|
/// | Agent **idle** + Enter (non-empty buffer) | Message is sent **immediately** to the agent (no tray, no delay). Recorded in scrollback as orange `you:`. |
/// | Agent **busy** + Enter (non-empty buffer) | Buffer text goes into the **queued tray** above the input box (orange `queued:` label, light-gray text on the input strip background). Not in scrollback yet. |
/// | Agent busy + queue exists + Enter on **empty** buffer | **Interrupts** the in-flight turn and **sends** the queued message. Recorded in scrollback at the moment the coordinator picks it up. |
/// | Agent busy + queue exists + types more + Enter | New buffer text **replaces** the queued message in the tray (single-slot queue). |
/// | Queue exists + **Ctrl+C** (1st press) | Queued message is moved back into the **input box** for editing. **The agent keeps running.** |
/// | No queue + agent busy + **Ctrl+C** (2nd press of the ladder) | Interrupts the agent. |
/// | No queue + agent idle + **Ctrl+C** (3rd press of the ladder) | Exits the chat. |
/// | Agent finishes a turn **naturally** with queue non-empty | Queued message is **auto-flushed** to the coordinator on the busy → idle transition. |
///
/// ### Ctrl+C ladder
///
/// When a queued message exists, three taps of Ctrl+C walk through three distinct states:
///
/// 1. **Recall** — first press pulls the queued message back into the input box so
///    you can edit it. The agent is unaffected and keeps streaming.
/// 2. **Interrupt** — second press (queue now empty, agent still busy) interrupts
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
  private var inputBuffer = ""
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
  }

  deinit {
    spinnerTask?.cancel()
  }

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
          scribeVersion: GitVersion.hash,
          persistURL: persistURL,
          logger: persistLog
        )

        let cwd = FileManager.default.currentDirectoryPath
        let gitBranch = SlateChatHost.detectGitBranch(cwd: cwd)
        sink.setBanner(
          baseURL: self.configuration.serverURL,
          model: self.configuration.agentModel,
          cwd: cwd,
          scribeVersion: GitVersion.hash,
          gitBranch: gitBranch,
          sessionId: self.sessionId.uuidString)

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
              prepareModelTurnStart: {
                interruptFlag.clear()
                interruptFlag.logState(sessionLog, tag: "cleared-for-new-turn")
              },
              shouldAbortTurn: {
                let v = interruptFlag.peek()
                if v {
                  sessionLog.trace(
                    """
                    event=chat.interrupt-flag.polled \
                    value=true
                    """)
                }
                return v
              },
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
            switch key {
            case .ctrl(3):
              // Ctrl+C: three-step ladder
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
                self.inputBuffer = queued
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
                self.modelInterruptFlag.logState(self.log, tag: "requested-by-ctrl-c")
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

            case .ctrl(4):
              self.log.debug("event=chat.user.ctrl-d action=exit")
              shouldStop = true

            case .bracketedPasteStart:
              self.inPaste = true

            case .bracketedPasteEnd:
              self.inPaste = false

            case .character(let ch):
              self.inputBuffer.append(ch)

            case .backspace:
              if !self.inPaste, !self.inputBuffer.isEmpty {
                self.inputBuffer.removeLast()
              }

            case .enter:
              if self.inPaste {
                // Pasted newlines stay literal
                self.inputBuffer.append("\n")
              } else {
                self.submitUserLine(sink: sink, gate: gate)
              }

            case .shiftEnter:
              self.inputBuffer.append("\n")
              self.log.debug(
                """
                event=chat.user.input.newline \
                source=shift-enter \
                buffer_chars=\(self.inputBuffer.count) \
                has_queue=\(self.queuedSubmission != nil)
                """)

            case .tab:
              if self.inPaste {
                self.inputBuffer.append("    ")
              }

            // Transcript scroll-back
            case .arrowUp:
              self.applyTranscriptScroll(delta: -1, sink: sink, slate: slate)
            case .arrowDown:
              self.applyTranscriptScroll(delta: +1, sink: sink, slate: slate)
            case .pageUp, .ctrl(2):
              self.applyTranscriptScrollPage(up: true, sink: sink, slate: slate)
            case .pageDown, .ctrl(6):
              self.applyTranscriptScrollPage(up: false, sink: sink, slate: slate)
            case .home:
              self.followingLiveTranscript = false
              self.transcriptFirstVisibleRow = 0
              self.renderWake?.requestRender()
            case .end:
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
          inputLine: self.inputBuffer,
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
            inputLine: self.inputBuffer,
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
            buffer_chars=\(self.inputBuffer.count)
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
    let submit = inputBuffer
    inputBuffer = ""
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
      inputLine: inputBuffer, waitingForLLM: sink.modelTurnBusy(),
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
      inputLine: inputBuffer, waitingForLLM: sink.modelTurnBusy(),
      queuedTrayText: sink.queuedTrayTextSnapshot())
    let page = max(1, contentRows)
    let delta = up ? -page : page
    applyTranscriptScroll(delta: delta, sink: sink, slate: slate)
  }

  /// Runs `git branch --show-current` in `cwd` and returns the branch name, or nil if not in a git repo.
  private static func detectGitBranch(cwd: String) -> String? {
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
