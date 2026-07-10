struct AgentTurnInterruptedError: Error, Sendable {
  init() {}
}

public enum TurnOutcome: Sendable, Equatable {
  case completed
  case interrupted
  case toolRoundLimit(rounds: Int)
  case error(String)
}

public struct ToolInvocation: Sendable, Equatable, Hashable {

  public let id: String

  public let name: String

  public let arguments: String

  public init(id: String, name: String, arguments: String) {
    self.id = id
    self.name = name
    self.arguments = arguments
  }
}
