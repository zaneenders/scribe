import Logging
import ScribeLLM

// MARK: - AgentHarnessProtocol

public protocol AgentHarnessProtocol: Sendable {
  var model: String { get }

  /// The tool registry derived from the same tool set the harness sends to the
  /// LLM.  Callers use this single source of truth for tool execution instead
  /// of constructing a separate `ToolRegistry`.
  var registry: ToolRegistry { get }

  /// Execute a single LLM round, returning a live stream of events plus a
  /// deferred result with the outcome and updated messages.
  func runRound(
    messages: [Components.Schemas.ChatMessage],
    logger: Logger,
    temperature: Double,
    shouldAbortTurn: @escaping @Sendable () -> Bool
  ) -> RoundStream
}
