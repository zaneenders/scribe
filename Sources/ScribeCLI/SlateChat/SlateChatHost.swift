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
}

// MARK: - Host types

/// Arrow / page keys mapped to transcript viewport motion (CSI, xterm-style).
private enum TranscriptScrollStep {
  case lineUp
  case lineDown
  case pageUp
  case pageDown
  /// ``ESC [ F`` (empty params): follow live tail / newest content.
  case snapToLiveBottom
  /// ``ESC [ H`` (empty params): jump to oldest buffered history in view.
  case snapToHistoryTop
}

/// Incremental word-wrap flatten of completed transcript lines (streaming only re-wraps the open tail).
private struct TranscriptFlattenCache {
  var wrapWidth: Int = -1
  var completedLogicalLines: Int = 0
  var completedFlat: [TLine] = []
}

// MARK: - Host

@MainActor
internal final class SlateChatHost {

  /// Xterm-compatible CSI final byte (`0x40`…`0x7E`): ends `\e[` parameter sequences incl. `…~` paste markers and `…u` kitty-style keys.
  /// Caller must require `accumulator.count >= 3` so `\e[` alone is not mistaken for complete CSI—the `[` byte (0x5B) sits in `0x40`…`0x7E`.
  private static func isCsiTerminator(_ byte: UInt8) -> Bool {
    byte >= 0x40 && byte <= 0x7E
  }

  private static let bracketPasteOpenSeq: ContiguousArray<UInt8> = [27, 91, 50, 48, 48, 126]
  private static let bracketPasteCloseSeq: ContiguousArray<UInt8> = [27, 91, 50, 48, 49, 126]

  /// Recognizes `\e[A` / `\e[B`, `\e[5~` / `\e[6~`, and bare `\e[H` / `\e[F` (cursor keys / paging / Home / End).
  private static func parseTranscriptScrollStep(fromCSI bytes: ContiguousArray<UInt8>) -> TranscriptScrollStep? {
    guard bytes.count >= 3, bytes[0] == 27, bytes[1] == 91 else { return nil }
    let terminator = bytes[bytes.count - 1]

    let paramRegion = bytes[2..<(bytes.count - 1)]
    guard let inner = String(bytes: paramRegion, encoding: .utf8) else { return nil }
    let ints = inner.split(separator: ";").compactMap { Int($0) }

    switch terminator {
    case UInt8(ascii: "A"):
      return .lineUp
    case UInt8(ascii: "B"):
      return .lineDown
    case UInt8(ascii: "H"):
      guard inner.isEmpty else { return nil }
      return .snapToHistoryTop
    case UInt8(ascii: "F"):
      guard inner.isEmpty else { return nil }
      return .snapToLiveBottom
    case UInt8(ascii: "~"):
      guard let k = ints.first else { return nil }
      if k == 5 { return .pageUp }
      if k == 6 { return .pageDown }
      return nil
    default:
      return nil
    }
  }

  private let configuration: AgentConfig
  private let client: Client
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
  /// Incomplete `\e`-led sequence (`\e[` CSI until terminator, or `\e` + immediate non-`[` char).
  private var escAccumulator: ContiguousArray<UInt8>?
  private var utf8Staging: ContiguousArray<UInt8> = []
  /// After a CR submit (`\r`), swallow the lone `\n` of a CRLF pair.
  private var swallowLfAfterCrSubmit = false
  private var bracketedPasteActive = false
  private var bracketCloseMatchPrefix = 0
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
  /// All chat events emitted from this host use this logger and the structured
  /// `event=ns.name k=v k=v` format documented in ``docs/chat-input-behavior.md``.
  private let log: Logger

  init(
    configuration: AgentConfig,
    client: Client,
    systemPrompt: String,
    resumeArchive: ChatSessionArchive?,
    sessionPersistenceURL: URL,
    sessionId: UUID,
    sessionCreatedAt: Date,
    log: Logger
  ) {
    self.configuration = configuration
    self.client = client
    self.systemPrompt = systemPrompt
    self.resumeArchive = resumeArchive
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
    let sink = SlateTranscriptSink()
    let gate = UserLineGate()

    // Bracketed paste: pasted text (possibly multi-byte or multi-line) is wrapped so newlines aren’t mistaken for submits.
    try? FileHandle.standardOutput.write(contentsOf: Data("\u{001b}[?2004h".utf8))
    defer {
      try? FileHandle.standardOutput.write(contentsOf: Data("\u{001b}[?2004l".utf8))
    }

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
        self.renderWake = wake
        let resumeSnapshot = self.resumeArchive
        if let resumed = resumeSnapshot {
          sink.replayPersistedConversation(resumed.messages)
          self.flattenCache = TranscriptFlattenCache()
        }

        let persistURL = self.sessionPersistenceURL
        let cid = self.sessionId
        let created = self.sessionCreatedAt
        let modelSnapshot = configuration.agentModel
        let baseSnapshot = configuration.openAIBaseURL
        let persistLog = self.log
        let persist: @Sendable ([Components.Schemas.ChatMessage]) -> Void = { history in
          let cwd = FileManager.default.currentDirectoryPath
          do {
            try ChatSessionStore.save(
              ChatSessionArchive(
                id: cid,
                createdAt: created,
                updatedAt: Date(),
                cwd: cwd,
                model: modelSnapshot,
                baseURL: baseSnapshot,
                messages: history
              ),
              to: persistURL
            )
            persistLog.trace(
              """
              event=chat.persist.save \
              messages=\(history.count) \
              path=\(persistURL.path)
              """
            )
          } catch {
            persistLog.error(
              """
              event=chat.persist.fail \
              path=\(persistURL.path) \
              err="\(error.localizedDescription)"
              """
            )
          }
        }

        let interruptFlag = self.modelInterruptFlag
        let sessionLog = self.log
        self.coordinatorTask = Task {
          [configuration, client, systemPrompt, sink, gate, resumeSnapshot, persist, interruptFlag, sessionLog] in
          defer { sink.markCoordinatorFinished() }
          do {
            try await ScribeAgentCoordinator.runInteractive(
              configuration: configuration,
              client: client,
              systemPrompt: systemPrompt,
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
            sink.emit(.harnessError(String(describing: error)))
            sessionLog.error(
              """
              event=chat.coordinator.fail \
              err="\(String(describing: error))"
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
          for byte in chunk {
            if sink.coordinatorFinished() {
              Task { await gate.complete(nil) }
              return .stop
            }
            if self.handleKey(byte: byte, sink: sink, gate: gate, slate: slate) {
              Task { await gate.complete(nil) }
              return .stop
            }
          }
        }
        // Auto-flush a queued tray message when the agent finishes a turn naturally
        // (busy → idle transition with the queue non-empty): hand it to the gate so the
        // coordinator picks it up on its next `readUserLine`, and clear the tray.
        let nowBusy = sink.modelTurnBusy()
        if !nowBusy, self.lastObservedModelBusy, let queued = self.queuedSubmission {
          self.log.debug(
            """
            event=chat.queue.auto-flush \
            trigger=busy-to-idle \
            chars=\(queued.count)
            """
          )
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
            queuedTrayText: queuedTrayText))
        // `slate.enscribe` builds the cell grid + encodes it + submits one frame to the
        // async tty writer. The actual `write(2)` happens off-actor, so a high `submit_ms`
        // here means encode/grid-build was expensive (transcript layout, grid blits) — *not*
        // tty drain. Splitting prepare/submit pinpoints which side any future regression
        // lives on.
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
            """
          )
        }
        return sink.coordinatorFinished() ? .stop : .continue
      })

    spinnerTask?.cancel()
    spinnerTask = nil
    renderWake = nil

    coordinatorTask?.cancel()
    await gate.complete(nil)
  }

  /// Handles ``Enter`` in the input box. The behaviour is:
  ///
  /// - **Empty buffer + no queued tray message** → no-op.
  /// - **Empty buffer + queued tray message** → interrupt the in-flight model turn (if any)
  ///   and dispatch the queued message to the coordinator (records it in scrollback the moment
  ///   the coordinator picks it up).
  /// - **Non-empty buffer + agent idle** → dispatch immediately (no tray, no delay): the
  ///   "first message goes straight to the agent" case.
  /// - **Non-empty buffer + agent busy** → place the buffer text into the queued tray
  ///   (replacing any earlier queued text). The user can then either edit + Enter to refine,
  ///   Enter on an empty buffer to send-via-interrupt, or Ctrl+C to recall the queued message.
  private func submitUserLine(sink: SlateTranscriptSink, gate: UserLineGate) {
    swallowLfAfterCrSubmit = true
    followingLiveTranscript = true
    transcriptFirstVisibleRow = 0
    let submit = inputBuffer
    inputBuffer = ""
    utf8Staging.removeAll(keepingCapacity: true)
    let trimmed = submit.trimmingCharacters(in: .whitespacesAndNewlines)
    let busy = sink.modelTurnBusy()
    let newlines = submit.reduce(0) { $0 + ($1 == "\n" ? 1 : 0) }

    if trimmed.isEmpty {
      // Second-Enter idiom: send the queued tray message now (interrupting if needed).
      guard let queued = queuedSubmission else {
        log.debug(
          """
          event=chat.user.submit \
          kind=noop \
          reason=empty-buffer-no-queue \
          model_busy=\(busy)
          """
        )
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
        """
      )
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
      // Park in the queued tray and wait for either the user (Enter / Ctrl+C) or for the
      // current turn to finish (auto-flushed in `onEvent`).
      let replacing = queuedSubmission != nil
      log.debug(
        """
        event=chat.user.submit \
        kind=queue \
        chars=\(submit.count) \
        newlines=\(newlines) \
        replacing=\(replacing) \
        model_busy=true
        """
      )
      queuedSubmission = submit
      sink.setQueuedTrayText(submit)
      renderWake?.requestRender()
    } else {
      // Agent is idle; dispatch immediately. Scrollback recording happens in the readUserLine
      // wrapper at pickup time.
      log.debug(
        """
        event=chat.user.submit \
        kind=immediate \
        chars=\(submit.count) \
        newlines=\(newlines) \
        model_busy=false
        """
      )
      Task { await gate.complete(submit) }
    }
  }

  /// Recomputes word-wrapped transcript rows, reusing flatten work for completed lines across streaming frames.
  private func syncFlattenedTranscript(sink: SlateTranscriptSink, slate: borrowing Slate) -> [TLine] {
    let (completed, open) = sink.snapshotTranscriptForLayout()
    let width = slate.cols

    if width != flattenCache.wrapWidth {
      flattenCache = TranscriptFlattenCache()
      flattenCache.wrapWidth = width
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

  private func applyTranscriptScroll(
    _ step: TranscriptScrollStep,
    sink: SlateTranscriptSink,
    slate: borrowing Slate
  ) {
    let flat = syncFlattenedTranscript(sink: sink, slate: slate)
    let contentRows = SlateChatRenderer.transcriptContentRows(
      cols: slate.cols,
      rows: slate.rows,
      banner: sink.bannerSnapshot(),
      usage: sink.usageHUDSnapshot(),
      inputLine: inputBuffer,
      waitingForLLM: sink.modelTurnBusy(),
      queuedTrayText: sink.queuedTrayTextSnapshot()
    )
    let page = max(1, contentRows)
    let maxTailStart = max(0, flat.count &- contentRows)

    switch step {
    case .snapToLiveBottom:
      followingLiveTranscript = true
      transcriptFirstVisibleRow = maxTailStart
    case .snapToHistoryTop:
      followingLiveTranscript = false
      transcriptFirstVisibleRow = 0
    case .lineUp, .pageUp:
      let delta = step == .lineUp ? 1 : page
      let wasFollowing = followingLiveTranscript
      followingLiveTranscript = false
      if wasFollowing {
        transcriptFirstVisibleRow = max(0, maxTailStart &- delta)
      } else {
        transcriptFirstVisibleRow = max(0, transcriptFirstVisibleRow &- delta)
      }
    case .lineDown, .pageDown:
      let delta = step == .lineDown ? 1 : page
      transcriptFirstVisibleRow = min(transcriptFirstVisibleRow &+ delta, maxTailStart)
      if transcriptFirstVisibleRow >= maxTailStart {
        followingLiveTranscript = true
      }
    }
    renderWake?.requestRender()
  }

  /// Inserts a soft newline into the input buffer and emits a `chat.user.input.newline`
  /// log line tagged with the originating key sequence. This is the single recorded path for
  /// Shift+Enter / Alt+Enter / Ctrl+J behaviour so the source key can be traced from the log.
  private func insertNewlineIntoInput(source: String) {
    inputBuffer.append("\n")
    log.debug(
      """
      event=chat.user.input.newline \
      source=\(source) \
      buffer_chars=\(inputBuffer.count) \
      has_queue=\(queuedSubmission != nil)
      """
    )
  }

  /// Returns `true` if the enclosing app should terminate (interrupt / EOF semantics).
  private func handleKey(byte: UInt8, sink: SlateTranscriptSink, gate: UserLineGate, slate: borrowing Slate) -> Bool {
    if byte == 3 {
      // Ctrl+C is a three-step ladder so the user can stage their reaction:
      //   1. With a queued tray message: pull it back into the input buffer for editing.
      //      The agent keeps running — this press only recalls the queued text.
      //   2. With no queue and an in-flight turn: interrupt the agent.
      //   3. With no queue and an idle prompt: exit the chat.
      let busy = sink.modelTurnBusy()
      if let queued = queuedSubmission {
        log.debug(
          """
          event=chat.user.ctrl-c \
          action=recall-queue \
          queue_chars=\(queued.count) \
          model_busy=\(busy)
          """
        )
        queuedSubmission = nil
        sink.setQueuedTrayText(nil)
        inputBuffer = queued
        utf8Staging.removeAll(keepingCapacity: true)
        renderWake?.requestRender()
        return false
      }
      if busy {
        log.debug(
          """
          event=chat.user.ctrl-c \
          action=interrupt-agent \
          model_busy=true
          """
        )
        modelInterruptFlag.request()
        renderWake?.requestRender()
        return false
      }
      log.debug(
        """
        event=chat.user.ctrl-c \
        action=exit \
        model_busy=false
        """
      )
      return true
    }
    if byte == 4 {
      log.debug("event=chat.user.ctrl-d action=exit")
      return true
    }

    if bracketedPasteActive {
      ingestBracketPasteByte(byte)
      return false
    }

    if var seq = escAccumulator {
      seq.append(byte)
      if seq.count >= 2, seq.first == 27, seq[1] != 91 {
        // `\e` + non-CSI: historically Option/Alt+Return sent ESC then CR/LF.
        escAccumulator = nil
        if byte == 10 || byte == 13 {
          insertNewlineIntoInput(source: "esc-prefix-cr-or-lf")
        } else {
          ingestUtf8Continuation(byte)
        }
        swallowLfAfterCrSubmit = false
        return false
      }
      escAccumulator = seq
      // Need at least `\e[<final>` — the `[` byte (0x5B) is in the terminator range (`0x40`…`0x7E`)
      // but is part of CSI's two-byte introducer, not the final parameter byte.
      if seq.count >= 3, seq[0] == 27, seq[1] == 91, let last = seq.last {
        if Self.isCsiTerminator(last) {
          escAccumulator = nil
          swallowLfAfterCrSubmit = false
          if let scroll = Self.parseTranscriptScrollStep(fromCSI: seq) {
            applyTranscriptScroll(scroll, sink: sink, slate: slate)
            return false
          }
          handleTerminatedCSI(seq, sink: sink, gate: gate)
          return false
        }
      }
      return false
    }

    if byte == 27 {
      escAccumulator = [27]
      return false
    }

    if byte == 10, swallowLfAfterCrSubmit {
      swallowLfAfterCrSubmit = false
      return false
    }
    if byte != 10 {
      swallowLfAfterCrSubmit = false
    }

    switch byte {
    case 13:
      submitUserLine(sink: sink, gate: gate)
    case 10:
      // Bare LF without a preceding CR — emitted by some terminals for Shift+Enter / Ctrl+J.
      insertNewlineIntoInput(source: "raw-lf")
    case 8, 127:
      removeLastLogicalCharacterFromInput()
    default:
      ingestUtf8Continuation(byte)
    }

    return false
  }

  /// Drop the last grapheme from the editable line (including staged UTF‑8 tails).
  private func removeLastLogicalCharacterFromInput() {
    guard !utf8Staging.isEmpty else {
      guard !inputBuffer.isEmpty else { return }
      inputBuffer.removeLast()
      return
    }

    utf8Staging.removeLast()
    while utf8Staging.count > 32 {
      utf8Staging.removeFirst()
      inputBuffer.unicodeScalars.append("\u{FFFD}")
    }

    while !utf8Staging.isEmpty, String(bytes: utf8Staging, encoding: .utf8) == nil {
      utf8Staging.removeLast()
    }
    collapseUtfStagingToBuffer()
  }

  private func ingestUtf8Continuation(_ byte: UInt8) {
    utf8Staging.append(byte)
    collapseUtfStagingToBuffer()

    guard utf8Staging.count > 8 else { return }
    utf8Staging.removeFirst()
    inputBuffer.unicodeScalars.append("\u{FFFD}")
    collapseUtfStagingToBuffer()
  }

  /// Moves complete UTF‑8 prefixes from staging into ``inputBuffer`` (leaves leftover bytes staged).
  private func collapseUtfStagingToBuffer() {
    while String(bytes: utf8Staging, encoding: .utf8) != nil, !utf8Staging.isEmpty {
      let decoded = utf8Staging
      utf8Staging.removeAll(keepingCapacity: true)
      guard let text = String(bytes: decoded, encoding: .utf8) else { return }
      for ch in text {
        switch ch {
        case Character(UnicodeScalar(0)): continue
        case "\u{001b}", "\u{007F}", "\u{0008}":
          continue
        default:
          inputBuffer.append(ch)
        }
      }
    }
  }

  /// Bracketed paste body (`\e[200~\` … `\e[201~`): literals only; close sequence is peeled off separately.
  private func ingestBracketPasteLiteral(_ byte: UInt8) {
    ingestUtf8Continuation(byte)
  }

  /// Detects `\e[201~` terminator while emitting every other byte as pasted text (including LF/Tab).
  private func ingestBracketPasteByte(_ byte: UInt8) {
    func flushCloseFalseStart() {
      for idx in 0..<bracketCloseMatchPrefix {
        ingestBracketPasteLiteral(Self.bracketPasteCloseSeq[idx])
      }
      bracketCloseMatchPrefix = 0
    }

    if byte == Self.bracketPasteCloseSeq[bracketCloseMatchPrefix] {
      bracketCloseMatchPrefix += 1
      if bracketCloseMatchPrefix == Self.bracketPasteCloseSeq.count {
        bracketCloseMatchPrefix = 0
        bracketedPasteActive = false
        collapseUtfStagingToBuffer()
        log.debug(
          """
          event=chat.user.input.paste-end \
          buffer_chars=\(inputBuffer.count)
          """
        )
      }
      return
    }

    if bracketCloseMatchPrefix > 0 {
      flushCloseFalseStart()
      ingestBracketPasteByte(byte)
      return
    }

    ingestBracketPasteLiteral(byte)
  }

  private func handleTerminatedCSI(
    _ bytes: ContiguousArray<UInt8>,
    sink _: SlateTranscriptSink,
    gate _: UserLineGate
  ) {
    if bytes.elementsEqual(Self.bracketPasteOpenSeq) {
      utf8Staging.removeAll(keepingCapacity: true)
      bracketedPasteActive = true
      bracketCloseMatchPrefix = 0
      log.debug(
        """
        event=chat.user.input.paste-begin \
        buffer_chars=\(inputBuffer.count)
        """
      )
      return
    }

    guard bytes.count >= 3, bytes[0] == 27, bytes[1] == 91 else { return }
    let terminator = bytes[bytes.count - 1]

    let paramRegion = bytes[2..<(bytes.count - 1)]
    guard let inner = String(bytes: paramRegion, encoding: .utf8) else { return }
    let ints = inner.split(separator: ";").compactMap { Int($0) }

    let csiSource: String
    switch terminator {
    case UInt8(ascii: "u"):
      // CSI u — plain Enter is `\r`. Non-zero modifier = soft newline (bitmask Shift=1, Alt=2, …).
      guard let key = ints.first, key == 13 else { return }
      guard ints.count >= 2, ints[1] != 0 else { return }
      csiSource = "csi-u-modified-enter mod=\(ints[1])"

    case UInt8(ascii: "~"):
      // Bracket paste open/close handled above; bracketed paste uses 200~/201~ digits.
      // xterm-style modified keys: `CSI 27 ; <modifier> ; 13 ~` (Shift+Enter often `27;2;13~`).
      if ints.count >= 3, ints[0] == 27, ints[2] == 13, ints[1] != 0 {
        csiSource = "csi-tilde-xterm-modified-enter mod=\(ints[1])"
        break
      }
      // Alternate `CSI 13 ; <modifier> ~` forms.
      if ints.count >= 2, ints[0] == 13, ints[1] != 0 {
        csiSource = "csi-tilde-modified-enter mod=\(ints[1])"
        break
      }
      return

    default:
      return
    }

    insertNewlineIntoInput(source: csiSource)
    swallowLfAfterCrSubmit = false
  }
}
