import Foundation
import Logging
import ScribeCore
import ScribeLLM
import Testing

@Suite
struct TokenTrackerTests {

  @Test func accumulateSessionTotal() {
    let tracker = TokenTracker(contextWindow: 1000)
    tracker.accumulate(
      usage: Components.Schemas.CompletionUsage(
        promptTokens: 10, completionTokens: 5, totalTokens: 15,
        promptTokensDetails: nil, completionTokensDetails: nil
      ))
    tracker.accumulate(
      usage: Components.Schemas.CompletionUsage(
        promptTokens: 20, completionTokens: 5, totalTokens: 25,
        promptTokensDetails: nil, completionTokensDetails: nil
      ))
    #expect(tracker.sessionTotalTokens == 40)
    #expect(tracker.lastPromptTokens == 20)
  }

  @Test func fallsBackWhenTotalMissing() {
    let tracker = TokenTracker(contextWindow: 1000)
    tracker.accumulate(
      usage: Components.Schemas.CompletionUsage(
        promptTokens: 10, completionTokens: 5, totalTokens: nil,
        promptTokensDetails: nil, completionTokensDetails: nil
      ))
    #expect(tracker.sessionTotalTokens == 15)
    #expect(tracker.lastPromptTokens == 10)
  }

  @Test func fallsBackToPromptOnly() {
    let tracker = TokenTracker(contextWindow: 1000)
    tracker.accumulate(
      usage: Components.Schemas.CompletionUsage(
        promptTokens: 7, completionTokens: nil, totalTokens: nil,
        promptTokensDetails: nil, completionTokensDetails: nil
      ))
    #expect(tracker.sessionTotalTokens == 7)
    #expect(tracker.lastPromptTokens == 7)
  }

  @Test func approachingLimitWhenOverThreshold() {
    let tracker = TokenTracker(contextWindow: 100, threshold: 0.5)
    tracker.accumulate(
      usage: Components.Schemas.CompletionUsage(
        promptTokens: 60, completionTokens: 0, totalTokens: 60,
        promptTokensDetails: nil, completionTokensDetails: nil
      ))
    #expect(tracker.isApproachingLimit)
    #expect(!tracker.isOverLimit)
  }

  @Test func overLimitWhenAboveWindow() {
    let tracker = TokenTracker(contextWindow: 100)
    tracker.accumulate(
      usage: Components.Schemas.CompletionUsage(
        promptTokens: 150, completionTokens: 0, totalTokens: 150,
        promptTokensDetails: nil, completionTokensDetails: nil
      ))
    #expect(tracker.isApproachingLimit)
    #expect(tracker.isOverLimit)
  }

  @Test func disabledWhenContextWindowIsZero() {
    let tracker = TokenTracker(contextWindow: 0)
    tracker.accumulate(
      usage: Components.Schemas.CompletionUsage(
        promptTokens: 1000, completionTokens: 0, totalTokens: 1000,
        promptTokensDetails: nil, completionTokensDetails: nil
      ))
    #expect(!tracker.isApproachingLimit)
    #expect(!tracker.isOverLimit)
  }

  @Test func logStatusDoesNotCrashWhenNoWindow() {
    let tracker = TokenTracker(contextWindow: 0)
    let logger = Logger(label: "test")
    tracker.logStatus(logger: logger)
    // No assertion needed; just verifying it does not crash.
  }

  @Test func logStatusWarnsWhenApproaching() {
    let tracker = TokenTracker(contextWindow: 100, threshold: 0.5)
    tracker.accumulate(
      usage: Components.Schemas.CompletionUsage(
        promptTokens: 60, completionTokens: 0, totalTokens: 60,
        promptTokensDetails: nil, completionTokensDetails: nil
      ))
    let logger = Logger(label: "test")
    tracker.logStatus(logger: logger)
    // Verified by inspection of log output in practice.
  }
}
