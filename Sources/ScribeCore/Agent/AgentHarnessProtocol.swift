import Logging
import ScribeLLM

// MARK: - AgentHarnessProtocol

public protocol AgentHarnessProtocol: Sendable {
  var model: String { get }

  func runRound(
    messages: inout [Components.Schemas.ChatMessage],
    logger: Logger,
    shouldAbortTurn: @escaping @Sendable () -> Bool
  ) async throws -> RoundOutcome
}
