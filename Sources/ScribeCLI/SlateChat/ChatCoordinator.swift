import Foundation
import Logging
import ScribeCore

/// Reference embedder that drives a ``ScribeAgent`` from a `lines` stream
/// of user submissions.
///
/// `ChatCoordinator` is intentionally narrow: it owns nothing UI-shaped
/// (Slate, `@MainActor`, terminal handling all live in ``SlateChatHost``)
/// and reaches for the ``ScribeAgent`` only through its public surface —
/// `prompt(...)`, `abort()`, and the ``TurnResult`` it returns. Copy this
/// file to ship Scribe inside a server or another tool; the only
/// outside-the-agent dependencies are ``ChatSessionStore`` (persistence)
/// and the `enqueue` callback (where transcript events are routed).
final class ChatCoordinator: Sendable {

  private let configuration: ScribeConfig
  private let resumeSnapshot: [ScribeMessage]
  private let log: Logger
  private let enqueue: @Sendable (HostEvent) -> Void
  private let persistURL: URL
  private let sessionId: UUID
  private let sessionCreatedAt: Date
  private let lines: AsyncStream<String>

  private let agent: ScribeAgent

  private let initialMessages: [ScribeMessage]

  init(
    configuration: ScribeConfig,
    systemPrompt: String,
    resumeSnapshot: [ScribeMessage],
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
      self.initialMessages = [ScribeMessage(role: .system, content: systemPrompt)]
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
    /// Append messages produced by the most recent turn to the JSONL store.
    /// Uses the messages returned by ``TurnResult`` rather than reaching back
    /// into the agent's internal buffer — keeping the coordinator on the
    /// public surface.
    func persistNew(
      allMessages: [ScribeMessage],
      persistedCount: Int
    ) {
      guard persistedCount < allMessages.count else { return }
      let newMessages = Array(allMessages[persistedCount...])
      do {
        try ChatSessionStore.appendMessages(newMessages, to: persistURL)
        log.trace(
          "chat.persist.append",
          metadata: [
            "new": "\(newMessages.count)",
            "total": "\(allMessages.count)",
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
        try ChatSessionStore.appendMessages(initialMessages, to: persistURL)
      }
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

        enqueue(.userSubmitted(trimmed))
        log.debug("event=agent.turn.dispatch chars=\(trimmed.count)")

        enqueue(.modelTurnRunning(true))
        defer { enqueue(.modelTurnRunning(false)) }

        let promptMessages: [ScribeMessage] = [ScribeMessage(role: .user, content: trimmed)]

        // Track the messages the agent committed during this turn so we can
        // persist + emit `turnComplete` without reaching back into the
        // agent's storage actor. Falls back to the agent's snapshot if the
        // turn never produced a TurnResult (e.g. HTTP error before stream).
        var committed: [ScribeMessage]? = nil
        do {
          let ts = await agent.stream(promptMessages, log: log)
          for await event in ts.events {
            if case .lifecycle(.usage(let usage, _)) = event { tracker.accumulate(usage: usage) }
            enqueue(.transcript(event))
          }
          let result = try await ts.result.value
          committed = result.messages
          switch result.outcome {
          case .completed:
            log.info("event=agent.turn.end status=completed")
            tracker.logStatus(logger: log)
          case .interrupted:
            log.notice("event=agent.turn.end status=interrupted")
            enqueue(.transcript(.lifecycle(.interrupted)))
          case .toolRoundLimit(let max):
            log.notice("event=agent.turn.end status=tool-round-limit limit=\(max)")
            enqueue(.transcript(.lifecycle(.interrupted)))
          }
        } catch {
          let se = (error as? ScribeError) ?? .generic(String(describing: error))
          log.error(
            "event=agent.turn.end status=error err=\"\(se.errorDescription ?? String(describing: se))\""
          )
          enqueue(.transcript(.lifecycle(.error(se))))
        }

        let allMessages: [ScribeMessage]
        if let committed {
          allMessages = committed
        } else {
          allMessages = await agent.messages
        }
        persistNew(allMessages: allMessages, persistedCount: persistedCount)
        persistedCount = allMessages.count
      }
      // Final flush in case the loop exited with un-persisted messages.
      let trailing = await agent.messages
      persistNew(allMessages: trailing, persistedCount: persistedCount)
      log.debug("event=chat.coordinator.end transcript_messages=\(trailing.count)")
    } catch {
      let scribeError = (error as? ScribeError) ?? .generic(String(describing: error))
      enqueue(.transcript(.lifecycle(.error(scribeError))))
      log.error(
        "chat.coordinator.fail",
        metadata: [
          "err": "\(scribeError.errorDescription ?? String(describing: scribeError))"
        ])
    }
    enqueue(.coordinatorFinished)
  }
}
