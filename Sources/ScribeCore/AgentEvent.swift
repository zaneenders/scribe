import Foundation

public enum AssistantStreamSection: Sendable, Equatable {
  case reasoning
  case answer
}

public enum MessageBoundaryRole: Sendable, Equatable {
  case user
  case assistant
  case tool
}

public enum TurnBoundaryOutcome: Sendable, Equatable {
  case completed
  case toolCalls(count: Int)
  case interrupted
  case error(String)
}

public enum AgentEvent: Sendable {
  case output(Output)
  case tool(Tool)
  case lifecycle(Lifecycle)

  case boundary(Boundary)

  public enum Output: Sendable {
    case sectionStarted(AssistantStreamSection, previous: AssistantStreamSection?)
    case text(AssistantStreamSection, String)
    case finalized
    case empty
  }

  public enum Tool: Sendable {
    case invocation(name: String, arguments: String, output: String)
    case warning(String)
  }

  public enum Lifecycle: Sendable {
    case usage(ScribeUsage, tokensPerSecond: Double?)
    case error(ScribeError)
    case interrupted

    case recovered(reason: String)
  }

  public enum Boundary: Sendable {
    case agentStart
    case agentEnd(TurnOutcome)
    case turnStart(round: Int)
    case turnEnd(round: Int, outcome: TurnBoundaryOutcome)
    case messageStart(role: MessageBoundaryRole, round: Int)
    case messageEnd(role: MessageBoundaryRole, round: Int)
    case toolExecutionStart(name: String, arguments: String)
    case toolExecutionEnd(name: String, output: String)
  }
}
