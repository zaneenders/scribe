import Foundation
import Logging
import ScribeCore

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

      logger.debug(
        "agent.turn.dispatch",
        metadata: ["chars": "\(trimmed.count)"])

      enqueue(.modelTurnRunning(true))
      defer { enqueue(.modelTurnRunning(false)) }

      do {
        _ = try await harness.submit(
          trimmed,
          onUserPrompt: { [enqueue] text in
            enqueue(.userSubmitted(text))
          }
        ) { [enqueue] event in
          enqueue(.transcript(event))
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
