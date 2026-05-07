import Logging
import ScribeLLM

// MARK: - AgentHarnessProtocol

public protocol AgentHarnessProtocol: Sendable {
  var model: String { get }

  /// Execute a single LLM round, returning a live stream of events plus a
  /// deferred result with the outcome and updated messages.
  func runRound(
    messages: [Components.Schemas.ChatMessage],
    logger: Logger,
    temperature: Double,
    shouldAbortTurn: @escaping @Sendable () -> Bool
  ) -> RoundStream
}
