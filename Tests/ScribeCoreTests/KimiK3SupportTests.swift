import Testing

@testable import ScribeCore

@Suite
struct KimiK3SupportTests {

  @Test func usesDocumentedDefaultMaxCompletionTokens() {
    #expect(
      KimiK3Support.effectiveMaxCompletionTokens(nil)
        == KimiK3Support.defaultMaxCompletionTokens)
    #expect(KimiK3Support.effectiveMaxCompletionTokens(8192) == 8192)
  }

  @Test func validatesDocumentedMaxCompletionTokensLimit() throws {
    try KimiK3Support.validateMaxCompletionTokens(KimiK3Support.maxCompletionTokensLimit)
    #expect(throws: ScribeError.self) {
      try KimiK3Support.validateMaxCompletionTokens(
        KimiK3Support.maxCompletionTokensLimit + 1)
    }
  }

  @Test func rejectsKimiCodeKeyWithMoonshotBaseURL() {
    #expect(throws: ScribeError.self) {
      try KimiK3Support.validateEndpoint(
        apiKey: "sk-kimi-test",
        serverURL: KimiK3Support.moonshotBaseURL
      )
    }
  }

  @Test func rejectsMoonshotKeyWithKimiCodeBaseURL() {
    #expect(throws: ScribeError.self) {
      try KimiK3Support.validateEndpoint(
        apiKey: "sk-platform-test",
        serverURL: KimiK3Support.kimiCodeBaseURL
      )
    }
  }

  @Test func acceptsKimiCodeKeyWithCodingBaseURL() throws {
    try KimiK3Support.validateEndpoint(
      apiKey: "sk-kimi-test",
      serverURL: KimiK3Support.kimiCodeBaseURL
    )
  }

  @Test func acceptsMoonshotKeyWithMoonshotBaseURL() throws {
    try KimiK3Support.validateEndpoint(
      apiKey: "sk-platform-test",
      serverURL: KimiK3Support.moonshotBaseURL
    )
  }

  @Test func resolvesKimiCodeTransport() throws {
    let transport = try KimiK3Support.resolveTransport(
      apiKey: "sk-kimi-test",
      serverURL: KimiK3Support.kimiCodeBaseURL
    )
    #expect(transport == .kimiCodeOpenAI)
  }

  @Test func resolvesMoonshotTransport() throws {
    let transport = try KimiK3Support.resolveTransport(
      apiKey: "sk-platform-test",
      serverURL: KimiK3Support.moonshotBaseURL
    )
    #expect(transport == .moonshotOpenAI)
  }

  @Test func ignoresLookalikeKimiCodeHosts() throws {
    #expect(!KimiK3Support.isKimiCodeBaseURL("https://notkimi.com/coding"))
    #expect(!KimiK3Support.isKimiCodeBaseURL("https://kimi.com.evil.example/coding"))
    #expect(!KimiK3Support.isKimiCodeBaseURL("https://api.kimi.com/other"))
    #expect(KimiK3Support.isKimiCodeBaseURL("https://api.kimi.com/coding/"))

    // Look-alike hosts are not treated as the Kimi Code endpoint.
    let transport = try KimiK3Support.resolveTransport(
      apiKey: "sk-platform-test",
      serverURL: "https://notkimi.com/coding"
    )
    #expect(transport == .moonshotOpenAI)
  }
}
