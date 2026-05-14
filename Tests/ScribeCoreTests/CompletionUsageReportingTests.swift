import Foundation
import ScribeCLI
import ScribeCore
import Testing

struct CompletionUsageReportingTests {
  @Test func groupingIntAddsThousandsSeparators() async throws {
    #expect(ScribeUsageFormatting.groupingInt(116975) == "116,975")
    #expect(ScribeUsageFormatting.groupingInt(12) == "12")
  }

  @Test func reportedTotalsFallsBackToSumWhenTotalMissing() async throws {
    let u = ScribeUsage(promptTokens: 100, completionTokens: 50, totalTokens: nil)
    let t = u.scribeReportedPromptCompletionTotal
    #expect(t?.prompt == 100)
    #expect(t?.completion == 50)
    #expect(t?.total == 150)
  }
}
