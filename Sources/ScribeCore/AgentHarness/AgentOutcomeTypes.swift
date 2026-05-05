// MARK: - Outcome types for agent turns and rounds

/// Thrown when an interactive host asks to stop the current model/tool round.
public struct AgentTurnInterruptedError: Error, Sendable {}

/// Result of ``AgentLoop/runModelTurn(messages:logger:shouldAbortTurn:)``.
public enum ModelTurnOutcome: Sendable, Equatable {
  case completed
}

/// Result of a single LLM round from ``AgentHarness/runRound(messages:logger:shouldAbortTurn:)``.
public enum RoundOutcome: Sendable, Equatable {
  case completed
  case toolCalls([ToolInvocation])
}

/// A resolved tool call produced by the assistant in a single round.
public struct ToolInvocation: Sendable, Equatable {
  public let id: String
  public let name: String
  public let arguments: String

  public init(id: String, name: String, arguments: String) {
    self.id = id
    self.name = name
    self.arguments = arguments
  }
}
