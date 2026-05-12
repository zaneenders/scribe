import Foundation
import Logging
import ScribeCore
import ScribeLLM

final class ChatCoordinator: Sendable {

  private let configuration: ScribeConfig
  private let resumeSnapshot: [Components.Schemas.ChatMessage]
  private let log: Logger
  private let enqueue: @Sendable (HostEvent) -> Void
  private let persistURL: URL
  private let sessionId: UUID
  private let sessionCreatedAt: Date
  private let lines: AsyncStream<String>

  private let agent: ScribeAgent

  private let initialMessages: [Components.Schemas.ChatMessage]

  init(
    configuration: ScribeConfig,
    systemPrompt: String,
    resumeSnapshot: [Components.Schemas.ChatMessage],
    log: Logger,
    enqueue: @escaping @Sendable (HostEvent) -> Void,
    persistURL: URL,
    sessionId: UUID,
    sessionCreatedAt: Date,
    lines: AsyncStream<String>
  ) throws {
    if !resumeSnapshot.isEmpty {
      guard resumeSnapshot.first?.role == .system else {
        throw ScribeError.sessionCorrupted(
          reason: "Resumed conversation must begin with a system message.")
      }
      self.initialMessages = resumeSnapshot
    } else {
      self.initialMessages = [.init(role: .system, content: systemPrompt)]
    }
    self.agent = try ScribeAgent(
      configuration: configuration,
      systemPrompt: systemPrompt,
      initialMessages: self.initialMessages
    )
    self.configuration = configuration
    self.resumeSnapshot = resumeSnapshot
    self.log = log
    self.enqueue = enqueue
    self.persistURL = persistURL
    self.sessionId = sessionId
    self.sessionCreatedAt = sessionCreatedAt
    self.lines = lines
  }

  func interrupt() {
    agent.abort()
  }

  func run() async {
    func persistNew(from agent: ScribeAgent, since count: Int) async {
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

        enqueue(.transcript(.userSubmitted(trimmed)))
        log.debug("event=agent.turn.dispatch chars=\(trimmed.count)")

        enqueue(.modelTurnRunning(true))
        defer { enqueue(.modelTurnRunning(false)) }

        do {
          let ts = await agent.prompt(trimmed, log: log)
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
