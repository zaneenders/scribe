import Foundation
import ScribeCore

public enum ScribeStreamSection: String, Sendable, Codable, Equatable {

  case reasoning

  case answer
}

public enum ScribeTurnOutcome: Sendable, Equatable {

  case completed

  case incomplete(reason: String?)

  case interrupted

  case toolRoundLimit(rounds: Int)

  case error(String)
}

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

public enum ScribeSessionEvent: Sendable, Equatable {

  case userPromptAccepted(String)

  case sectionStarted(ScribeStreamSection)

  case sectionTextAppended(ScribeStreamSection, text: String)

  case toolRoundStarted(round: Int)

  case toolInvocationStarted(name: String, arguments: String)

  case toolInvocationCompleted(name: String, output: String)

  case warning(String)

  case error(String)

  case retrying(attempt: Int, maxAttempts: Int, delaySeconds: Double, reason: String)

  case recovered(reason: String)

  case usage(ScribeUsageSnapshot)

  case emptyOutput

  case interrupted

  case identityChanged(previousSessionID: UUID, sessionID: UUID)

  case turnCompleted(ScribeTurnOutcome, messages: [ScribeMessage])

  case turnFailed(String)

  public var isTerminal: Bool {
    switch self {
    case .turnCompleted, .turnFailed: return true
    default: return false
    }
  }
}
