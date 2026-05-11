import Foundation
import Logging
import ScribeCore
import ScribeLLM
import Synchronization

// MARK: - ChatCoordinator

/// Actor that owns the agent-turn loop: reads user input lines from an AsyncStream,
/// processes them through an `AgentProtocol` implementation, and emits `HostEvent`s
/// to a callback.
///
/// Extracted from `SlateChatHost` to make the turn-loop testable without a TUI.
actor ChatCoordinator {

  private let makeAgent: AgentFactory
  private let systemPrompt: String
  private let resumeSnapshot: [Components.Schemas.ChatMessage]
  private let interruptFlag: ModelTurnInterruptFlag
  private let log: Logger
  private let enqueue: (HostEvent) -> Void
  private let persistURL: URL
  private let sessionId: UUID
  private let sessionCreatedAt: Date
  private let lines: AsyncStream<String>
  private let configuration: ScribeConfig

  init(
    configuration: ScribeConfig,
    systemPrompt: String,
    resumeSnapshot: [Components.Schemas.ChatMessage],
    interruptFlag: ModelTurnInterruptFlag,
    log: Logger,
    enqueue: @escaping @Sendable (HostEvent) -> Void,
    persistURL: URL,
    sessionId: UUID,
    sessionCreatedAt: Date,
    lines: AsyncStream<String>,
    makeAgent: @escaping AgentFactory
  ) {
    self.configuration = configuration
    self.systemPrompt = systemPrompt
    self.resumeSnapshot = resumeSnapshot
    self.interruptFlag = interruptFlag
    self.log = log
    self.enqueue = enqueue
    self.persistURL = persistURL
    self.sessionId = sessionId
    self.sessionCreatedAt = sessionCreatedAt
    self.lines = lines
    self.makeAgent = makeAgent
  }

  func run() async {
    func persistNew(from agent: any AgentProtocol, since count: Int) async {
      let newMessages = await agent.messages(since: count)
      guard !newMessages.isEmpty else { return }
      do {
        try ChatSessionStore.appendMessages(newMessages, to: persistURL)
        let total = await agent.messages.count
        log.trace(
          "chat.persist.append",
          metadata: [
            "new": "\(newMessages.count)",
            "total": "\(total)",
            "path": "\(persistURL.path)",
          ])
      } catch {
        log.error(
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

      let agent = try await makeAgent(initialMessages)

      // Write metadata on first persist (new sessions only).
      if resumeSnapshot.isEmpty {
        let cwd = FileManager.default.currentDirectoryPath
        let meta = ChatSessionMetadata(
          id: sessionId,
          createdAt: sessionCreatedAt,
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
      log.debug(
        "event=chat.coordinator.start messages=\(msgCount) resumed=\(!resumeSnapshot.isEmpty)")

      let tracker = TokenTracker(
        contextWindow: configuration.contextWindow,
        threshold: configuration.contextWindowThreshold
      )

      for await line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "exit" {
          log.notice("event=chat.user.exit-command")
          break
        }
        if trimmed.isEmpty {
          log.trace("event=chat.user.empty-skip")
          continue
        }

        // Record user submission into transcript.
        enqueue(.transcript(.userSubmitted(trimmed)))
        log.debug("event=agent.turn.dispatch chars=\(trimmed.count)")

        interruptFlag.clear()
        interruptFlag.logState(log, tag: "cleared-for-new-turn")
        enqueue(.modelTurnRunning(true))
        defer { enqueue(.modelTurnRunning(false)) }

        let options = AgentRunOptions(
          shouldAbortTurn: { [interruptFlag, log] in
            let v = interruptFlag.peek()
            if v { log.trace("chat.interrupt-flag.polled", metadata: ["value": "true"]) }
            return v
          }
        )

        do {
          let ts = await agent.prompt(trimmed, options: options, log: log)
          for await event in ts.events {
            if case .usage(let usage, _) = event { tracker.accumulate(usage: usage) }
            enqueue(.transcript(event))
          }
          let result = try await ts.result.value
          switch result.outcome {
          case .completed:
            log.info("event=agent.turn.end status=completed")
            tracker.logStatus(logger: log)
          case .interrupted:
            log.notice("event=agent.turn.end status=interrupted")
            enqueue(.transcript(.turnInterrupted))
          case .toolRoundLimit(let max):
            log.notice("event=agent.turn.end status=tool-round-limit limit=\(max)")
            enqueue(.transcript(.turnInterrupted))
          }
        } catch {
          let se = (error as? ScribeError) ?? .generic(String(describing: error))
          log.error(
            "event=agent.turn.end status=error err=\"\(se.errorDescription ?? String(describing: se))\""
          )
          enqueue(.transcript(.harnessError(se)))
        }
        await persistNew(from: agent, since: persistedCount)
        persistedCount = await agent.messages.count

        // Turn complete — tell host to finalize.
        let committed = await agent.messages
        enqueue(.transcript(.turnComplete(referenceMessages: committed)))
      }
      await persistNew(from: agent, since: persistedCount)
      let finalMsgCount = await agent.messages.count
      log.debug("event=chat.coordinator.end transcript_messages=\(finalMsgCount)")
    } catch {
      let scribeError = (error as? ScribeError) ?? .generic(String(describing: error))
      enqueue(.transcript(.harnessError(scribeError)))
      log.error(
        "chat.coordinator.fail",
        metadata: [
          "err": "\(scribeError.errorDescription ?? String(describing: scribeError))"
        ])
    }
    enqueue(.coordinatorFinished)
  }
}

// MARK: - ModelTurnInterruptFlag (extracted from host)

/// Cooperative abort for Ctrl+C during an assistant/tool round without
/// cancelling the long-lived coordinator task.
final class ModelTurnInterruptFlag: Sendable {
  private let lock = Mutex(false)

  func clear() { lock.withLock { $0 = false } }
  func request() { lock.withLock { $0 = true } }
  func peek() -> Bool { lock.withLock { $0 } }

  func logState(_ logger: Logger, tag: String) {
    let val = peek()
    logger.trace("chat.interrupt-flag.\(tag)", metadata: ["value": "\(val)"])
  }
}
