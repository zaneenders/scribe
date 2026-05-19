import Foundation

public enum AssistantStreamSection: Sendable, Equatable {
  case reasoning
  case answer
}

/// Events emitted by the agent harness during a turn.
public enum TranscriptEvent: Sendable {
  case enterAssistantSection(AssistantStreamSection, previous: AssistantStreamSection?)
  case appendAssistantText(AssistantStreamSection, text: String)
  case finalizeAssistantStream
  case emptyAssistantTurn
  case toolInvocation(name: String, arguments: String, output: String)
  case usage(ScribeUsage, tokensPerSecond: Double?)
  case harnessError(ScribeError)
  case turnInterrupted
  case warning(String)
}
