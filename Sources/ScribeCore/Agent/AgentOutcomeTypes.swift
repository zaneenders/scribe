// MARK: - Outcome types for agent turns and rounds

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
struct ToolInvocation: Sendable, Equatable {
  let id: String
  let name: String
  let arguments: String

  init(id: String, name: String, arguments: String) {
    self.id = id
    self.name = name
    self.arguments = arguments
  }
}
