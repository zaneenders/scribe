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

// MARK: - Transcript flatten cache (static on TranscriptLayout)

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
  private var flattenCache = TranscriptLayout.FlattenCache()

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
    let sink = SlateTranscriptSink(theme: .default)
    let gate = UserLineGate()

    await slate.subscribe(
      prepare: { [self] wake in
        sink.installWake(wake)
        sink.setContextWindow(self.configuration.contextWindow)
        self.renderWake = wake

        let resumeSnapshot = self.resumeMessages
        if !resumeSnapshot.isEmpty {
          TranscriptReplay.replay(
            messages: resumeSnapshot,
            onEvent: { sink.emit($0) },
            recordUserSubmission: { sink.recordUserSubmission(trimmedVisible: $0) }
          )
          self.flattenCache = TranscriptLayout.FlattenCache()
        }

        let persistURL = self.sessionPersistenceURL

        let cwd = FileManager.default.currentDirectoryPath
        sink.setBanner(
          baseURL: self.configuration.serverURL,
          model: self.configuration.agentModel,
          cwd: cwd,
          scribeVersion: GitVersion.hash,
          gitBranch: nil,
          sessionId: self.sessionId.uuidString)
        // Detect git branch asynchronously — avoids blocking the main actor on Process.waitUntilExit().
        let baseURL = self.configuration.serverURL
        let model = self.configuration.agentModel
        let version = GitVersion.hash
        let sid = self.sessionId.uuidString
        Task.detached(priority: .background) { [weak sink] in
          if let branch = SlateChatHost.detectGitBranch(cwd: cwd) {
            sink?.setBanner(
              baseURL: baseURL,
              model: model,
              cwd: cwd,
              scribeVersion: version,
              gitBranch: branch,
              sessionId: sid)
          }
        }

        let interruptFlag = self.modelInterruptFlag
        let sessionLog = self.log
        self.coordinatorTask = Task {
          [
            configuration, systemPrompt, sink, gate, resumeSnapshot, interruptFlag, sessionLog
          ] in
          defer { sink.markCoordinatorFinished() }

          func persistNew(from agent: ScribeAgent, since count: Int) async {
            let current = await agent.messages
            guard current.count > count else { return }
            let newMessages = Array(current[count...])
            do {
              try ChatSessionStore.appendMessages(newMessages, to: persistURL)
              sessionLog.trace(
                "chat.persist.append",
                metadata: [
                  "new": "\(newMessages.count)",
                  "total": "\(current.count)",
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

            // Write metadata on first persist (new sessions only — resume keeps existing metadata).
            if resumeSnapshot.isEmpty {
              let cwd = FileManager.default.currentDirectoryPath
              let meta = ChatSessionMetadata(
                id: self.sessionId,
                createdAt: self.sessionCreatedAt,
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
              await persistNew(from: agent, since: persistedCount)
              persistedCount = await agent.messages.count
            }
            await persistNew(from: agent, since: persistedCount)
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
      coalesceMaxFPS: 60,
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
          let actions = self.inputHandler.handle(chunk)

          for action in actions {
            switch action {
            case .enter:
              let text = self.inputHandler.takeBuffer()
              self.submitCoordinator.setModelBusy(sink.modelTurnBusy())
              let effect = self.submitCoordinator.handleEnter(text: text)
              shouldStop = self.applySubmitEffect(effect, gate: gate, sink: sink)

            case .ctrlC:
              let (effect, recallText) = self.submitCoordinator.handleCtrlC()
              if let recall = recallText {
                self.inputHandler.setBuffer(recall)
                sink.setQueuedTrayText(nil)
                self.renderWake?.requestRender()
              }
              shouldStop = self.applySubmitEffect(effect, gate: gate, sink: sink)

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
        let nowBusy = sink.modelTurnBusy()
        self.submitCoordinator.setModelBusy(nowBusy)
        let flushEffect = self.submitCoordinator.handleModelTurnEnd()
        if case .sendToGate(let text) = flushEffect {
          self.log.debug(
            "chat.queue.auto-flush",
            metadata: ["trigger": "busy-to-idle", "chars": "\(text.count)"])
          sink.setQueuedTrayText(nil)
          Task { await gate.complete(text) }
        }

        // Render frame — all layout + paint inside slate.with {} to access grid dimensions.
        slate.with { grid in
          let scrCols = grid.cols
          let scrRows = grid.rows

          let prepareStart = Date()
          let (completed, open, generation) = sink.snapshotTranscriptForLayout()
          let flatTranscript = TranscriptLayout.FlattenCache.flatten(
            cache: &self.flattenCache,
            completed: completed,
            open: open,
            width: scrCols,
            generation: generation)
          let queuedTrayText = sink.queuedTrayTextSnapshot()
          let contentRows = SlateChatRenderer.transcriptContentRows(
            cols: scrCols,
            rows: scrRows,
            banner: sink.bannerSnapshot(),
            usage: sink.usageHUDSnapshot(),
            inputLine: self.inputHandler.buffer,
            waitingForLLM: sink.modelTurnBusy(),
            queuedTrayText: queuedTrayText)
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
            banner: sink.bannerSnapshot(),
            usage: sink.usageHUDSnapshot(),
            inputLine: self.inputHandler.buffer,
            llmWaitAnimationFrame: self.llmWaitAnimationFrame,
            waitingForLLM: sink.modelTurnBusy(),
            queuedTrayText: queuedTrayText,
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
        return sink.coordinatorFinished() ? .stop : .continue
      })

    spinnerTask?.cancel()
    spinnerTask = nil
    renderWake = nil

    coordinatorTask?.cancel()
    await gate.complete(nil)
  }

  // MARK: - Submit effect dispatch

  /// Execute a `SubmitEffect` against the gate, sink, and interrupt flag.
  /// Returns `true` if the chat loop should stop.
  private func applySubmitEffect(
    _ effect: SubmitEffect,
    gate: UserLineGate,
    sink: SlateTranscriptSink
  ) -> Bool {
    switch effect {
    case .sendToGate(let text):
      Task { await gate.complete(text) }

    case .interruptAndSend(let text):
      modelInterruptFlag.request()
      modelInterruptFlag.logState(log, tag: "interrupt-and-send")
      Task { await gate.complete(text) }

    case .setQueued(let text):
      sink.setQueuedTrayText(text)

    case .clearQueued:
      sink.setQueuedTrayText(nil)

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
