import Foundation

public enum AssistantStreamSection: Sendable, Equatable {
  case reasoning
  case answer
}

/// Role tag for message boundary events.
public enum MessageBoundaryRole: Sendable, Equatable {
  case user
  case assistant
  case tool
}

/// Why an LLM round ended (for ``AgentEvent/Boundary/turnEnd``).
public enum TurnBoundaryOutcome: Sendable, Equatable {
  case completed
  case toolCalls(count: Int)
  case interrupted
}

/// Events emitted by the agent harness during a turn.
public enum AgentEvent: Sendable {
  case output(Output)
  case tool(Tool)
  case lifecycle(Lifecycle)
  /// Turn and message boundaries for embedders and plugins.
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
    /// Emitted when the harness recovered from a recoverable error
    /// (e.g. tool output blew the context window) by rolling back
    /// the offending messages and replacing them with a synthetic
    /// tool error so the model can self-correct.
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
