// MARK: - Outcome types for agent turns and rounds

/// Thrown when an interactive host asks to stop the current model/tool round.
public struct AgentTurnInterruptedError: Error, Sendable {
  public init() {}
}

/// Result of a full agent turn (one user prompt through completion or interruption).
public enum TurnOutcome: Sendable, Equatable {
  case completed
  case interrupted
  case toolRoundLimit(rounds: Int)
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
