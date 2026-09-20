import Foundation
import ScribeCore

/// Section of a streamed assistant turn.
public enum ScribeStreamSection: String, Sendable, Codable, Equatable {

  case reasoning

  case answer
}

/// `TurnOutcome`-equivalent value carried by the terminal completion event.
public enum ScribeTurnOutcome: Sendable, Equatable {

  case completed

  case incomplete(reason: String?)

  case interrupted

  case toolRoundLimit(rounds: Int)

  case error(String)
}

/// Token usage snapshot reported during or after a turn.
public struct ScribeUsageSnapshot: Codable, Sendable, Equatable {

  public var totalTokens: Int?

  public var tokensPerSecond: Double?

  public init(totalTokens: Int? = nil, tokensPerSecond: Double? = nil) {
    self.totalTokens = totalTokens
    self.tokensPerSecond = tokensPerSecond
  }

  public init(_ usage: ScribeUsage, tokensPerSecond: Double?) {
    self.totalTokens = usage.totalTokens
    self.tokensPerSecond = tokensPerSecond
  }
}

public enum ScribeSessionEventCodingError: Error, Sendable, Equatable {

  /// The event carries a tag this decoder does not know. Unknown future tags
  /// fail explicitly instead of being treated as completion.
  case unknownTag(String)

  case malformedPayload(tag: String, details: String)
}

/// One tagged, Codable session event. Every successful submission stream
/// emits exactly one terminal event (`turnCompleted` or `turnFailed`) and then
/// finishes. Events carry structured data; the shared reducer owns titles and
/// presentation decisions.
public enum ScribeSessionEvent: Sendable, Equatable {

  /// The submitted prompt was accepted and persisted.
  case userPromptAccepted(String)

  /// A reasoning or answer section began streaming.
  case sectionStarted(ScribeStreamSection)

  /// Text was appended to the given streaming section.
  case sectionTextAppended(ScribeStreamSection, text: String)

  /// A new tool round within the current turn began.
  case toolRoundStarted(round: Int)

  /// A tool invocation began executing.
  case toolInvocationStarted(name: String, arguments: String)

  /// A tool invocation finished with its raw JSON output.
  case toolInvocationCompleted(name: String, output: String)

  /// Non-fatal warning surfaced during the turn.
  case warning(String)

  /// Non-fatal error surfaced during the turn; the turn continues.
  case error(String)

  /// A transient failure is being retried.
  case retrying(attempt: Int, maxAttempts: Int, delaySeconds: Double, reason: String)

  /// A transient failure recovered without ending the turn.
  case recovered(reason: String)

  /// Token usage update for the current turn.
  case usage(ScribeUsageSnapshot)

  /// The model produced no output for the turn.
  case emptyOutput

  /// The current turn was interrupted; a terminal event still follows.
  case interrupted

  /// The session identity changed (fork or TLDR); replay IDs are now scoped
  /// to the new session identifier.
  case identityChanged(previousSessionID: UUID, sessionID: UUID)

  /// Terminal success. Carries the outcome and the authoritative persisted
  /// messages after the turn, letting the reducer reconcile provisional
  /// streamed identities into deterministic replay identities.
  case turnCompleted(ScribeTurnOutcome, messages: [ScribeMessage])

  /// Terminal failure with a display-safe message. The stream finishes after
  /// this event.
  case turnFailed(String)

  public var isTerminal: Bool {
    switch self {
    case .turnCompleted, .turnFailed: return true
    default: return false
    }
  }
}

extension ScribeSessionEvent: Codable {

  private enum Tag: String {
    case userPromptAccepted = "user_prompt_accepted"
    case sectionStarted = "section_started"
    case sectionTextAppended = "section_text_appended"
    case toolRoundStarted = "tool_round_started"
    case toolInvocationStarted = "tool_invocation_started"
    case toolInvocationCompleted = "tool_invocation_completed"
    case warning
    case error
    case retrying
    case recovered
    case usage
    case emptyOutput = "empty_output"
    case interrupted
    case identityChanged = "identity_changed"
    case turnCompleted = "turn_completed"
    case turnFailed = "turn_failed"
  }

  private enum CodingKeys: String, CodingKey {
    case type
    case section
    case text
    case round
    case name
    case arguments
    case output
    case message
    case attempt
    case maxAttempts = "max_attempts"
    case delaySeconds = "delay_seconds"
    case reason
    case usage
    case previousSessionID = "previous_session_id"
    case sessionID = "session_id"
    case outcome
    case messages
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let rawTag = try container.decode(String.self, forKey: .type)
    guard let tag = Tag(rawValue: rawTag) else {
      throw ScribeSessionEventCodingError.unknownTag(rawTag)
    }
    switch tag {
    case .userPromptAccepted:
      self = .userPromptAccepted(try container.decode(String.self, forKey: .text))
    case .sectionStarted:
      self = .sectionStarted(try container.decode(ScribeStreamSection.self, forKey: .section))
    case .sectionTextAppended:
      self = .sectionTextAppended(
        try container.decode(ScribeStreamSection.self, forKey: .section),
        text: try container.decode(String.self, forKey: .text))
    case .toolRoundStarted:
      self = .toolRoundStarted(round: try container.decode(Int.self, forKey: .round))
    case .toolInvocationStarted:
      self = .toolInvocationStarted(
        name: try container.decode(String.self, forKey: .name),
        arguments: try container.decode(String.self, forKey: .arguments))
    case .toolInvocationCompleted:
      self = .toolInvocationCompleted(
        name: try container.decode(String.self, forKey: .name),
        output: try container.decode(String.self, forKey: .output))
    case .warning:
      self = .warning(try container.decode(String.self, forKey: .message))
    case .error:
      self = .error(try container.decode(String.self, forKey: .message))
    case .retrying:
      self = .retrying(
        attempt: try container.decode(Int.self, forKey: .attempt),
        maxAttempts: try container.decode(Int.self, forKey: .maxAttempts),
        delaySeconds: try container.decode(Double.self, forKey: .delaySeconds),
        reason: try container.decode(String.self, forKey: .reason))
    case .recovered:
      self = .recovered(reason: try container.decode(String.self, forKey: .reason))
    case .usage:
      self = .usage(try container.decode(ScribeUsageSnapshot.self, forKey: .usage))
    case .emptyOutput:
      self = .emptyOutput
    case .interrupted:
      self = .interrupted
    case .identityChanged:
      self = .identityChanged(
        previousSessionID: try container.decode(UUID.self, forKey: .previousSessionID),
        sessionID: try container.decode(UUID.self, forKey: .sessionID))
    case .turnCompleted:
      self = .turnCompleted(
        try container.decode(ScribeTurnOutcome.self, forKey: .outcome),
        messages: try container.decode([ScribeMessage].self, forKey: .messages))
    case .turnFailed:
      self = .turnFailed(try container.decode(String.self, forKey: .message))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .userPromptAccepted(let text):
      try container.encode(Tag.userPromptAccepted.rawValue, forKey: .type)
      try container.encode(text, forKey: .text)
    case .sectionStarted(let section):
      try container.encode(Tag.sectionStarted.rawValue, forKey: .type)
      try container.encode(section, forKey: .section)
    case .sectionTextAppended(let section, let text):
      try container.encode(Tag.sectionTextAppended.rawValue, forKey: .type)
      try container.encode(section, forKey: .section)
      try container.encode(text, forKey: .text)
    case .toolRoundStarted(let round):
      try container.encode(Tag.toolRoundStarted.rawValue, forKey: .type)
      try container.encode(round, forKey: .round)
    case .toolInvocationStarted(let name, let arguments):
      try container.encode(Tag.toolInvocationStarted.rawValue, forKey: .type)
      try container.encode(name, forKey: .name)
      try container.encode(arguments, forKey: .arguments)
    case .toolInvocationCompleted(let name, let output):
      try container.encode(Tag.toolInvocationCompleted.rawValue, forKey: .type)
      try container.encode(name, forKey: .name)
      try container.encode(output, forKey: .output)
    case .warning(let message):
      try container.encode(Tag.warning.rawValue, forKey: .type)
      try container.encode(message, forKey: .message)
    case .error(let message):
      try container.encode(Tag.error.rawValue, forKey: .type)
      try container.encode(message, forKey: .message)
    case .retrying(let attempt, let maxAttempts, let delaySeconds, let reason):
      try container.encode(Tag.retrying.rawValue, forKey: .type)
      try container.encode(attempt, forKey: .attempt)
      try container.encode(maxAttempts, forKey: .maxAttempts)
      try container.encode(delaySeconds, forKey: .delaySeconds)
      try container.encode(reason, forKey: .reason)
    case .recovered(let reason):
      try container.encode(Tag.recovered.rawValue, forKey: .type)
      try container.encode(reason, forKey: .reason)
    case .usage(let usage):
      try container.encode(Tag.usage.rawValue, forKey: .type)
      try container.encode(usage, forKey: .usage)
    case .emptyOutput:
      try container.encode(Tag.emptyOutput.rawValue, forKey: .type)
    case .interrupted:
      try container.encode(Tag.interrupted.rawValue, forKey: .type)
    case .identityChanged(let previousSessionID, let sessionID):
      try container.encode(Tag.identityChanged.rawValue, forKey: .type)
      try container.encode(previousSessionID, forKey: .previousSessionID)
      try container.encode(sessionID, forKey: .sessionID)
    case .turnCompleted(let outcome, let messages):
      try container.encode(Tag.turnCompleted.rawValue, forKey: .type)
      try container.encode(outcome, forKey: .outcome)
      try container.encode(messages, forKey: .messages)
    case .turnFailed(let message):
      try container.encode(Tag.turnFailed.rawValue, forKey: .type)
      try container.encode(message, forKey: .message)
    }
  }
}

extension ScribeTurnOutcome: Codable {

  private enum Kind: String {
    case completed
    case incomplete
    case interrupted
    case toolRoundLimit = "tool_round_limit"
    case error
  }

  private enum CodingKeys: String, CodingKey {
    case kind
    case reason
    case rounds
    case message
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let rawKind = try container.decode(String.self, forKey: .kind)
    switch rawKind {
    case Kind.completed.rawValue:
      self = .completed
    case Kind.incomplete.rawValue:
      self = .incomplete(reason: try container.decodeIfPresent(String.self, forKey: .reason))
    case Kind.interrupted.rawValue:
      self = .interrupted
    case Kind.toolRoundLimit.rawValue:
      self = .toolRoundLimit(rounds: try container.decode(Int.self, forKey: .rounds))
    case Kind.error.rawValue:
      self = .error(try container.decode(String.self, forKey: .message))
    default:
      throw ScribeSessionEventCodingError.unknownTag(rawKind)
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .completed:
      try container.encode(Kind.completed.rawValue, forKey: .kind)
    case .incomplete(let reason):
      try container.encode(Kind.incomplete.rawValue, forKey: .kind)
      try container.encodeIfPresent(reason, forKey: .reason)
    case .interrupted:
      try container.encode(Kind.interrupted.rawValue, forKey: .kind)
    case .toolRoundLimit(let rounds):
      try container.encode(Kind.toolRoundLimit.rawValue, forKey: .kind)
      try container.encode(rounds, forKey: .rounds)
    case .error(let message):
      try container.encode(Kind.error.rawValue, forKey: .kind)
      try container.encode(message, forKey: .message)
    }
  }
}
