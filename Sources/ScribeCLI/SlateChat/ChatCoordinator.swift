import Foundation
import Logging
import ScribeCore

/// Reference embedder that drives a ``SessionHarness`` from a `lines` stream.
///
/// `ChatCoordinator` is intentionally narrow: it owns nothing UI-shaped
/// (Slate, `@MainActor`, terminal handling all live in ``SlateChatHost``)
/// and delegates session lifecycle to ``SessionHarness``. Copy this file to
/// ship Scribe inside a server or another tool; the only outside-the-harness
/// dependency is the `enqueue` callback (where transcript events are routed).
final class ChatCoordinator: Sendable {

  private let harness: SessionHarness
  private let logger: Logger
  private let enqueue: @Sendable (HostEvent) -> Void
  private let lines: AsyncStream<String>

  init(
    harness: SessionHarness,
    logger: Logger,
    enqueue: @escaping @Sendable (HostEvent) -> Void,
    lines: AsyncStream<String>
  ) {
    self.harness = harness
    self.logger = logger
    self.enqueue = enqueue
    self.lines = lines
  }

  func interrupt() {
    Task { await harness.interrupt() }
  }

  func run() async {
    let initialCount = await harness.messageCount
    logger.debug(
      "chat.coordinator.start",
      metadata: ["messages": "\(initialCount)"])

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

      do {
        let outcome = try await harness.submit(trimmed) { [enqueue] event in
          enqueue(.transcript(event))
        }
        switch outcome {
        case .completed:
          break
        case .interrupted:
          break
        case .toolRoundLimit:
          break
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
    let finalCount = await harness.messageCount
    logger.debug(
      "chat.coordinator.end",
      metadata: ["transcript_messages": "\(finalCount)"])
    enqueue(.coordinatorFinished)
  }
}
