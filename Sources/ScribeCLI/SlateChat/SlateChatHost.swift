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
      "chat.interrupt-flag.\(tag)",
      metadata: [
        "value": "\(val)"
      ])
  }
}

private struct TranscriptFlattenCache {
  var wrapWidth: Int = -1
  var completedLogicalLines: Int = 0
  var completedFlat: [TLine] = []
  var lastGeneration: Int = -1
}

@MainActor
internal final class SlateChatHost {

  private let configuration: ScribeConfig
  private let systemPrompt: String
  private let resumeArchive: ChatSessionArchive?
  private let sessionPersistenceURL: URL
  private let sessionId: UUID
  private let sessionCreatedAt: Date
  private var inputBuffer = ""
  private var transcriptFirstVisibleRow: Int = 0
  private var followingLiveTranscript: Bool = true
  private var flattenCache = TranscriptFlattenCache()
  private var keyDecoder = TerminalKeyDecoder()
  private var inPaste = false
  private var renderWake: ExternalWake?
  private var llmWaitAnimationFrame: Int = 0
  private var spinnerTask: Task<Void, Never>?
  private var coordinatorTask: Task<Void, Never>?
  private let modelInterruptFlag = ModelTurnInterruptFlag()
  private var queuedSubmission: String? = nil
  private var lastObservedModelBusy: Bool = false
  private let log: Logger

  init(
    configuration: ScribeConfig,
    systemPrompt: String,
    resumeArchive: ChatSessionArchive?,
    sessionPersistenceURL: URL,
    sessionId: UUID,
    sessionCreatedAt: Date,
    log: Logger
  ) {
    self.configuration = configuration
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
            configuration, systemPrompt, sink, gate, resumeSnapshot, persist, interruptFlag, sessionLog
          ] in
          defer { sink.markCoordinatorFinished() }
          do {
            // Build initial messages
            let initialMessages: [Components.Schemas.ChatMessage]
            if let resumed = resumeSnapshot?.messages, !resumed.isEmpty {
              guard resumed.first?.role == .system else {
                throw ScribeError.sessionCorrupted(
                  reason: "Resumed conversation must begin with a system message.")
              }
              initialMessages = resumed
            } else {
              initialMessages = [
                .init(role: .system, content: systemPrompt)
              ]
            }

            let agent = try ScribeAgent(
              configuration: configuration,
              systemPrompt: systemPrompt,
              initialMessages: initialMessages
            )

            persist(initialMessages)
            let msgCount = initialMessages.count
            sessionLog.debug("event=chat.coordinator.start messages=\(msgCount) resumed=\(resumeSnapshot != nil)")

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

              // Record visible submission
              sink.recordUserSubmission(trimmedVisible: trimmed)
              sessionLog.debug("event=agent.turn.dispatch chars=\(trimmed.count)")

              interruptFlag.clear()
              interruptFlag.logState(sessionLog, tag: "cleared-for-new-turn")
              sink.emit(.modelTurnRunning(true))
              defer { sink.emit(.modelTurnRunning(false)) }

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
                  sink.emit(event)
                }
                let result = try await ts.result.value
                switch result.outcome {
                case .completed:
                  sessionLog.info("event=agent.turn.end status=completed")
                  tracker.logStatus(logger: sessionLog)
                case .interrupted:
                  sessionLog.notice("event=agent.turn.end status=interrupted")
                  sink.emit(.turnInterrupted)
                case .toolRoundLimit(let max):
                  sessionLog.notice("event=agent.turn.end status=tool-round-limit limit=\(max)")
                  sink.emit(.turnInterrupted)
                }
              } catch {
                let se = (error as? ScribeError) ?? .generic(String(describing: error))
                sessionLog.error(
                  "event=agent.turn.end status=error err=\"\(se.errorDescription ?? String(describing: se))\"")
                sink.emit(.harnessError(se))
              }
              persist(await agent.messages)
            }
            persist(await agent.messages)
            let finalMsgCount = await agent.messages.count
            sessionLog.debug("event=chat.coordinator.end transcript_messages=\(finalMsgCount)")
          } catch {
            let scribeError = (error as? ScribeError) ?? .generic(String(describing: error))
            sink.emit(.harnessError(scribeError))
            sessionLog.error(
              "chat.coordinator.fail",
              metadata: [
                "err": "\(scribeError.errorDescription ?? String(describing: scribeError))"
              ])
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
                  "chat.user.ctrl-c",
                  metadata: [
                    "action": "recall-queue",
                    "queue_chars": "\(queued.count)",
                    "model_busy": "\(busy)",
                  ])
                self.queuedSubmission = nil
                sink.setQueuedTrayText(nil)
                self.inputBuffer = queued
                self.renderWake?.requestRender()
              } else if busy {
                // 2. Interrupt in-flight turn
                self.log.debug(
                  "chat.user.ctrl-c",
                  metadata: [
                    "action": "interrupt-agent",
                    "model_busy": "true",
                  ])
                self.modelInterruptFlag.request()
                self.modelInterruptFlag.logState(self.log, tag: "requested-by-ctrl-c")
                self.renderWake?.requestRender()
              } else {
                // 3. Exit chat
                self.log.debug(
                  "chat.user.ctrl-c",
                  metadata: [
                    "action": "exit",
                    "model_busy": "false",
                  ])
                shouldStop = true
              }

            case .ctrl(4):
              self.log.debug(
                "chat.user.ctrl-d",
                metadata: ["action": "exit"])
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
                "chat.user.input.newline",
                metadata: [
                  "source": "shift-enter",
                  "buffer_chars": "\(self.inputBuffer.count)",
                  "has_queue": "\(self.queuedSubmission != nil)",
                ])

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
            "chat.queue.auto-flush",
            metadata: [
              "trigger": "busy-to-idle",
              "chars": "\(queued.count)",
            ])
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
            "chat.render.slow",
            metadata: [
              "elapsed_ms": "\(totalMs)",
              "prepare_ms": "\(prepareMs)",
              "submit_ms": "\(submitMs)",
              "flat_rows": "\(flatTranscript.count)",
              "cols": "\(slate.cols)",
              "rows": "\(slate.rows)",
              "model_busy": "\(nowBusy)",
              "queue_chars": "\(self.queuedSubmission?.count ?? 0)",
              "buffer_chars": "\(self.inputBuffer.count)",
            ])
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
          "chat.user.submit",
          metadata: [
            "kind": "noop",
            "reason": "empty-buffer-no-queue",
            "model_busy": "\(busy)",
          ])
        return
      }
      let queuedNewlines = queued.reduce(0) { $0 + ($1 == "\n" ? 1 : 0) }
      log.debug(
        "chat.user.submit",
        metadata: [
          "kind": "interrupt-and-send",
          "chars": "\(queued.count)",
          "newlines": "\(queuedNewlines)",
          "model_busy": "\(busy)",
        ])
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
        "chat.user.submit",
        metadata: [
          "kind": "queue",
          "chars": "\(submit.count)",
          "newlines": "\(newlines)",
          "replacing": "\(replacing)",
          "model_busy": "true",
        ])
      queuedSubmission = submit
      sink.setQueuedTrayText(submit)
      renderWake?.requestRender()
    } else {
      log.debug(
        "chat.user.submit",
        metadata: [
          "kind": "immediate",
          "chars": "\(submit.count)",
          "newlines": "\(newlines)",
          "model_busy": "false",
        ])
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
