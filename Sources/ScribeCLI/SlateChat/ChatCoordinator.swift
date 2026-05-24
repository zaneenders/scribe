import Foundation
import Logging
import ScribeCore
import SystemPackage

/// Reference embedder that drives a ``ScribeAgent`` from a `lines` stream
/// of user submissions, on top of a host-owned ``SessionDocument``.
///
/// `ChatCoordinator` is intentionally narrow: it owns nothing UI-shaped
/// (Slate, `@MainActor`, terminal handling all live in ``SlateChatHost``)
/// and no longer owns persistence either — the document handles that
/// through its ``SessionPersister``. Copy this file to ship Scribe inside
/// a server or another tool; the only outside-the-agent dependencies are
/// two `@MainActor` closures into the host (where the doc lives) and the
/// `enqueue` callback (where transcript events are routed).
final class ChatCoordinator: Sendable {

  private let configuration: ScribeConfig
  private let logger: Logger
  private let enqueue: @Sendable (HostEvent) -> Void
  private let lines: AsyncStream<String>
  /// Borrow the host-owned document long enough to copy out a snapshot.
  /// Runs on the MainActor; the doc is borrowed without any await so
  /// the call is always safe.
  private let snapshot: @MainActor @Sendable () -> [ScribeMessage]
  /// Append a turn's worth of new messages to the host-owned document.
  /// The closure body hops to the MainActor and routes the append
  /// through the host's persist-first / commit-second orchestrator —
  /// that's the only path that mutates the doc from the coordinator.
  private let applyAppend: @MainActor @Sendable ([ScribeMessage]) async throws -> Void
  /// Read the current message count from the host-owned doc (for the
  /// start/end log lines).
  private let documentCount: @MainActor @Sendable () -> Int
  private let agent: ScribeAgent

  init(
    configuration: ScribeConfig,
    logger: Logger,
    enqueue: @escaping @Sendable (HostEvent) -> Void,
    snapshot: @escaping @MainActor @Sendable () -> [ScribeMessage],
    applyAppend: @escaping @MainActor @Sendable ([ScribeMessage]) async throws -> Void,
    documentCount: @escaping @MainActor @Sendable () -> Int,
    lines: AsyncStream<String>
  ) throws {
    self.agent = try ScribeAgent(
      configuration: configuration,
      logger: logger
    )
    self.configuration = configuration
    self.logger = logger
    self.enqueue = enqueue
    self.snapshot = snapshot
    self.applyAppend = applyAppend
    self.documentCount = documentCount
    self.lines = lines
  }

  func interrupt() {
    agent.abort()
  }

  func run() async {
    let initialCount = await documentCount()
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

      // Borrow the doc on the MainActor for a snapshot, then run the
      // turn without holding the doc. New messages get folded back into
      // the doc only after the turn completes.
      let history = await snapshot()

      do {
        let ts = agent.run(promptMessages, history: history)
        for await event in ts.events {
          if case .lifecycle(.usage(let usage, _)) = event { tracker.accumulate(usage: usage) }
          enqueue(.transcript(event))
        }
        let result = try await ts.result.value
        // Fold the turn's diff back into the host's doc.
        if !result.newMessages.isEmpty {
          try await applyAppend(result.newMessages)
        }
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
    let finalCount = await documentCount()
    logger.debug(
      "chat.coordinator.end",
      metadata: ["transcript_messages": "\(finalCount)"])
    enqueue(.coordinatorFinished)
  }
}
