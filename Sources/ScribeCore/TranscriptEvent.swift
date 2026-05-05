import Foundation
import ScribeLLM

public enum AssistantStreamSection: Sendable, Equatable {
  case reasoning
  case answer
}

/// Events emitted by the agent harness and coordinator so a host can render transcript updates.
/// Replaces the previous ``ScribeAgentOutput`` protocol with a single closure boundary.
public enum TranscriptEvent: Sendable {
  case enterAssistantSection(AssistantStreamSection, previous: AssistantStreamSection?)
  case appendAssistantText(AssistantStreamSection, text: String)
  case finalizeAssistantStream
  case emptyAssistantTurn
  case usage(Components.Schemas.CompletionUsage, tokensPerSecond: Double?)
  case blankLine
  case toolRoundHeader(round: Int, toolNames: [String])
  case toolInvocation(name: String, arguments: String, output: String)
  case skippedUnreadableStreamLine
  case harnessError(ScribeError)
  case turnInterrupted
  case modelTurnRunning(Bool)
}
