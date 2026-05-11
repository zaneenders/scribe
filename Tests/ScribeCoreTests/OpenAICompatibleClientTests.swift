import Foundation
import OpenAPIRuntime
import Testing

@testable import ScribeLLM

@Suite
struct OpenAICompatibleClientTests {
  @Test
  func makeReturnsClient() {
    _ = OpenAICompatibleClient.make(
      serverURL: URL(string: "http://127.0.0.1:11434")!,
      apiKey: nil
    )
    #expect(Bool(true))
  }

  @Test
  func makeWithAPIKeyReturnsClient() {
    _ = OpenAICompatibleClient.make(
      serverURL: URL(string: "http://127.0.0.1:11434")!,
      apiKey: "sk-test"
    )
    #expect(Bool(true))
  }

  @Test
  func makeWithEmptyAPIKeyReturnsClient() {
    _ = OpenAICompatibleClient.make(
      serverURL: URL(string: "http://127.0.0.1:11434")!,
      apiKey: ""
    )
    #expect(Bool(true))
  }
}
