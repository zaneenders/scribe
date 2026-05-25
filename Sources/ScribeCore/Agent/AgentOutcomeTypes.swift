
/// Thrown when an interactive host asks to stop the current model/tool round.
struct AgentTurnInterruptedError: Error, Sendable {
  init() {}
}

/// Result of a full agent turn (one user prompt through completion or interruption).
public enum TurnOutcome: Sendable, Equatable {
  case completed
  case interrupted
  case toolRoundLimit(rounds: Int)
}

/// A resolved tool call produced by the assistant in a single round.
///
/// Surfaced publicly so embedders providing their own ``ToolExecutor`` can
/// receive the resolved invocation (`id`, `name`, JSON-encoded `arguments`)
/// without depending on the OpenAI wire schema.
public struct ToolInvocation: Sendable, Equatable, Hashable {
  /// Provider-generated identifier (echoed back as `tool_call_id` on the
  /// resulting tool message).
  public let id: String
  /// Tool name as the assistant requested it (must match a registered tool).
  public let name: String
  /// JSON-encoded argument blob from the model. Schema validation is the
  /// executor's responsibility.
  public let arguments: String

  public init(id: String, name: String, arguments: String) {
    self.id = id
    self.name = name
    self.arguments = arguments
  }
}
