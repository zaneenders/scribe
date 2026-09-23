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

/// Streamed session event. Successful streams emit one terminal event.
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
