import Foundation
import ScribeCore
import ScribeLLM
import Testing

struct CompletionUsageReportingTests {
  @Test func groupingIntAddsThousandsSeparators() async throws {
    #expect(ScribeUsageFormatting.groupingInt(116975) == "116,975")
    #expect(ScribeUsageFormatting.groupingInt(12) == "12")
  }

  @Test func reportedTotalsFallsBackToSumWhenTotalMissing() async throws {
    let u = Components.Schemas.CompletionUsage(
      promptTokens: 100, completionTokens: 50, totalTokens: nil, promptTokensDetails: nil,
      completionTokensDetails: nil)
    let t = u.scribeReportedPromptCompletionTotal
    #expect(t?.prompt == 100)
    #expect(t?.completion == 50)
    #expect(t?.total == 150)
  }

  @Test func nestedDetailsRoundTripThroughJSON() async throws {
    let json = """
    {"prompt_tokens":10,"completion_tokens":20,"total_tokens":30,
     "prompt_tokens_details":{"cached_tokens":8},
     "completion_tokens_details":{"reasoning_tokens":12}}
    """
    let u = try JSONDecoder().decode(Components.Schemas.CompletionUsage.self, from: Data(json.utf8))
    #expect(u.promptTokensDetails?.cachedTokens == 8)
    #expect(u.completionTokensDetails?.reasoningTokens == 12)
  }
}
