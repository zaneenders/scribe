import Foundation
import ScribeLLM

public enum AssistantStreamSection: Sendable, Equatable {
  case reasoning
  case answer
}

/// Events emitted by the agent harness and coordinator so a host can render transcript updates.
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

  /// A user submitted text — the host should render a "you:" entry in the transcript.
  case userSubmitted(String)
  /// Turn ended; the host should rebuild its transcript cache from the agent's
  /// committed message list (the single source of truth).
  case reconcileFromAgent([Components.Schemas.ChatMessage])
}
