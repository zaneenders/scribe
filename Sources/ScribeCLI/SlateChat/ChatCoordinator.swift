import Foundation
import Logging
import ScribeCore
import SystemPackage

/// Reference embedder that drives a ``ScribeAgent`` from a `lines` stream
/// of user submissions, on top of a caller-owned ``SessionDocument``.
///
/// `ChatCoordinator` is intentionally narrow: it owns nothing UI-shaped
/// (Slate, `@MainActor`, terminal handling all live in ``SlateChatHost``)
/// and no longer owns persistence either — the document handles that
/// through its ``SessionPersister``. Copy this file to ship Scribe inside
/// a server or another tool; the only outside-the-agent dependencies are
/// a `SessionDocument` (shared by the host so `/fork` and `/tldr` can
/// mutate the same state) and the `enqueue` callback (where transcript
/// events are routed).
final class ChatCoordinator: Sendable {

  private let configuration: ScribeConfig
  private let logger: Logger
  private let enqueue: @Sendable (HostEvent) -> Void
  private let lines: AsyncStream<String>
  private let document: SessionDocument
  private let agent: ScribeAgent

  init(
    configuration: ScribeConfig,
    logger: Logger,
    enqueue: @escaping @Sendable (HostEvent) -> Void,
    document: SessionDocument,
    lines: AsyncStream<String>
  ) throws {
    self.agent = try ScribeAgent(
      configuration: configuration,
      document: document,
      logger: logger
    )
    self.configuration = configuration
    self.logger = logger
    self.enqueue = enqueue
    self.document = document
    self.lines = lines
  }

  func interrupt() {
    agent.abort()
  }

  func run() async {
    let initialCount = await document.count
    logger.debug(
      "chat.coordinator.start",
      metadata: ["messages": "\(initialCount)"])

    let tracker = TokenTracker(
      contextWindow: configuration.contextWindow,
      threshold: configuration.contextWindowThreshold
    )

    for await line in lines {
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed == "exit" {
        logger.notice("chat.user.exit-command")
        break
      }
      if trimmed.isEmpty {
        logger.trace("chat.user.empty-skip")
        continue
      }

      enqueue(.userSubmitted(trimmed))
      logger.debug(
        "agent.turn.dispatch",
        metadata: ["chars": "\(trimmed.count)"])

      enqueue(.modelTurnRunning(true))
      defer { enqueue(.modelTurnRunning(false)) }

      let promptMessages: [ScribeMessage] = [ScribeMessage(role: .user, content: trimmed)]

      do {
        let ts = await agent.stream(promptMessages)
        for await event in ts.events {
          if case .lifecycle(.usage(let usage, _)) = event { tracker.accumulate(usage: usage) }
          enqueue(.transcript(event))
        }
        let result = try await ts.result.value
        switch result.outcome {
        case .completed:
          logger.info("agent.turn.end", metadata: ["status": "completed"])
          tracker.logStatus(logger: logger)
        case .interrupted:
          logger.notice("agent.turn.end", metadata: ["status": "interrupted"])
        case .toolRoundLimit(let max):
          logger.notice(
            "agent.turn.end",
            metadata: ["status": "tool-round-limit", "limit": "\(max)"])
          enqueue(.transcript(.lifecycle(.interrupted)))
        }
      } catch {
        let se = (error as? ScribeError) ?? .generic(String(describing: error))
        logger.error(
          "agent.turn.end",
          metadata: [
            "status": "error",
            "err": "\(se.errorDescription ?? String(describing: se))",
          ])
        enqueue(.transcript(.lifecycle(.error(se))))
      }
    }
    let finalCount = await document.count
    logger.debug(
      "chat.coordinator.end",
      metadata: ["transcript_messages": "\(finalCount)"])
    enqueue(.coordinatorFinished)
  }
}
