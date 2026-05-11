import Foundation
import ScribeCLI
import ScribeCore
import ScribeLLM
import Testing

@Suite
struct CompletionUsageReportingExtendedTests {
  // MARK: - groupingInt edge cases

  @Test
  func groupingIntZero() {
    #expect(ScribeUsageFormatting.groupingInt(0) == "0")
  }

  @Test
  func groupingIntLargeNumber() {
    #expect(ScribeUsageFormatting.groupingInt(1_234_567_890) == "1,234,567,890")
  }

  @Test
  func groupingIntNegative() {
    // Negative numbers are unlikely but the formatter should handle them.
    #expect(ScribeUsageFormatting.groupingInt(-1234) == "-1,234")
  }

  // MARK: - scribeReportedPromptCompletionTotal

  @Test
  func reportedTotalsUsesStatedTotalWhenPresent() {
    let u = Components.Schemas.CompletionUsage(
      promptTokens: 100, completionTokens: 50, totalTokens: 200,
      promptTokensDetails: nil, completionTokensDetails: nil)
    let t = u.scribeReportedPromptCompletionTotal
    #expect(t?.prompt == 100)
    #expect(t?.completion == 50)
    #expect(t?.total == 200)
  }

  @Test
  func reportedTotalsReturnsNilWhenAllZero() {
    let u = Components.Schemas.CompletionUsage(
      promptTokens: 0, completionTokens: 0, totalTokens: 0,
      promptTokensDetails: nil, completionTokensDetails: nil)
    let t = u.scribeReportedPromptCompletionTotal
    #expect(t == nil)
  }

  @Test
  func reportedTotalsReturnsNilWhenAllNil() {
    let u = Components.Schemas.CompletionUsage(
      promptTokens: nil, completionTokens: nil, totalTokens: nil,
      promptTokensDetails: nil, completionTokensDetails: nil)
    let t = u.scribeReportedPromptCompletionTotal
    #expect(t == nil)
  }

  @Test
  func reportedTotalsPromptOnly() {
    let u = Components.Schemas.CompletionUsage(
      promptTokens: 50, completionTokens: nil, totalTokens: nil,
      promptTokensDetails: nil, completionTokensDetails: nil)
    let t = u.scribeReportedPromptCompletionTotal
    #expect(t?.prompt == 50)
    #expect(t?.completion == 0)
    #expect(t?.total == 50)
  }

  @Test
  func reportedTotalsCompletionOnly() {
    let u = Components.Schemas.CompletionUsage(
      promptTokens: nil, completionTokens: 30, totalTokens: nil,
      promptTokensDetails: nil, completionTokensDetails: nil)
    let t = u.scribeReportedPromptCompletionTotal
    #expect(t?.prompt == 0)
    #expect(t?.completion == 30)
    #expect(t?.total == 30)
  }

  @Test
  func reportedTotalsAllNilTokensReturnsNil() {
    let u = Components.Schemas.CompletionUsage(
      promptTokens: nil, completionTokens: nil, totalTokens: 0,
      promptTokensDetails: nil, completionTokensDetails: nil)
    let t = u.scribeReportedPromptCompletionTotal
    #expect(t == nil)
  }

  @Test
  func reportedTotalsStatedTotalZeroWithPromptTokens() {
    // If stated total is 0 but prompt + completion > 0, uses sum.
    let u = Components.Schemas.CompletionUsage(
      promptTokens: 60, completionTokens: 40, totalTokens: 0,
      promptTokensDetails: nil, completionTokensDetails: nil)
    let t = u.scribeReportedPromptCompletionTotal
    #expect(t?.prompt == 60)
    #expect(t?.completion == 40)
    #expect(t?.total == 100)
  }
}
