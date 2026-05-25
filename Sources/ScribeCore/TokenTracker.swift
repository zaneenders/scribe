import Foundation
import Logging
import Synchronization

public final class TokenTracker: Sendable {
  private let state = Mutex(State())

  private struct State {
    var sessionTotalTokens: Int = 0
    var lastPromptTokens: Int = 0
  }

  public let contextWindow: Int
  public let threshold: Double

  public init(contextWindow: Int, threshold: Double = 0.8) {
    self.contextWindow = contextWindow
    self.threshold = threshold
  }

  public func accumulate(usage: ScribeUsage) {
    state.withLock { state in
      if let total = usage.totalTokens, total > 0 {
        state.sessionTotalTokens += total
      } else if let prompt = usage.promptTokens, let completion = usage.completionTokens,
        prompt + completion > 0
      {
        state.sessionTotalTokens += prompt + completion
      } else if let prompt = usage.promptTokens, prompt > 0 {
        state.sessionTotalTokens += prompt
      }

      if let prompt = usage.promptTokens, prompt > 0 {
        state.lastPromptTokens = prompt
      } else if let total = usage.totalTokens, let completion = usage.completionTokens,
        total > completion
      {
        state.lastPromptTokens = total - completion
      }
    }
  }

  public var sessionTotalTokens: Int {
    state.withLock { $0.sessionTotalTokens }
  }

  public var lastPromptTokens: Int {
    state.withLock { $0.lastPromptTokens }
  }

  public var isApproachingLimit: Bool {
    guard contextWindow > 0 else { return false }
    return lastPromptTokens > Int(Double(contextWindow) * threshold)
  }

  public var isOverLimit: Bool {
    guard contextWindow > 0 else { return false }
    return lastPromptTokens > contextWindow
  }

  public func logStatus(logger: Logger) {
    guard contextWindow > 0 else { return }
    let prompt = lastPromptTokens
    let pct = Int(Double(prompt) / Double(contextWindow) * 100)
    if isOverLimit {
      logger.warning(
        "token-tracker.over-limit",
        metadata: [
          "last_prompt_tokens": "\(prompt)",
          "context_window": "\(contextWindow)",
          "pct": "\(pct)",
        ])
    } else if isApproachingLimit {
      logger.warning(
        "token-tracker.approaching-limit",
        metadata: [
          "last_prompt_tokens": "\(prompt)",
          "context_window": "\(contextWindow)",
          "threshold": "\(threshold)",
          "pct": "\(pct)",
        ])
    }
  }
}
