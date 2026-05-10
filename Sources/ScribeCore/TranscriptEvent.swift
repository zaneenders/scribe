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

  /// A user submitted text — the host should render a "you:" entry in the transcript.
  case userSubmitted(String)
  /// Turn completed; carries the agent's committed message list for
  /// consistency comparison (streaming render vs batch render).
  /// The host should NOT rebuild from these messages — the streaming path
  /// is authoritative.  Differences are logged as warnings for later test-casing.
  case turnComplete(referenceMessages: [Components.Schemas.ChatMessage])
}
