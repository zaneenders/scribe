@testable import ScribeCore
import Testing

@Suite
struct KimiK3SupportTests {

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
}
