import Foundation

public enum AssistantStreamSection: Sendable, Equatable {
  case reasoning
  case answer
}

/// Events emitted by the agent harness during a turn.
public enum AgentEvent: Sendable {
  case output(Output)
  case tool(Tool)
  case lifecycle(Lifecycle)

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
}
