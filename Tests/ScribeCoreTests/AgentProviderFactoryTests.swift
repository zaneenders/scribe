import Foundation
import Testing

@testable import ScribeCore

@Suite
struct AgentProviderFactoryTests {

  // MARK: - Factory helper

  private func configuration(
    model: String = "test-model",
    serverURL: String = "https://api.example.com",
    apiKey: String? = "test-key",
    apiType: String? = nil,
    contextWindow: Int = 128_000,
    reasoningEnabled: Bool? = nil,
    reasoningEffort: String? = nil,
    maxTokens: Int? = nil
  ) -> ScribeConfig {
    ScribeConfig(
      agentModel: model,
      contextWindow: contextWindow,
      contextWindowThreshold: 0.75,
      serverURL: serverURL,
      apiKey: apiKey,
      apiType: apiType,
      workingDirectory: "/tmp",
      reasoningEnabled: reasoningEnabled,
      reasoningEffort: reasoningEffort,
      maxTokens: maxTokens
    )
  }

  // MARK: - Invalid server URL

  @Test("throws on empty serverURL")
  func throwsOnEmptyServerURL() {
    let config = configuration(serverURL: "")

    #expect(throws: ScribeError.self) {
      _ = try AgentProviderFactory.make(configuration: config)
    }
  }

  // MARK: - Provider-selection matrix (default / unknown / explicit OpenAI)

  @Test(
    "provider selection returns OpenAICompletionsProvider",
    arguments: [
      (apiType: nil as String?, label: "nil → standard"),
      (apiType: "unknown-type" as String?, label: "unknown → standard"),
      (apiType: "openai" as String?, label: "explicit openai → standard"),
    ])
  func providerSelectionMatrix(apiType: String?, label: String) throws {
    let config = configuration(apiType: apiType)
    let provider = try AgentProviderFactory.make(configuration: config)
    #expect(provider is OpenAICompletionsProvider)
  }

  // MARK: - Codex provider

  @Test("codex apiType returns CodexProvider with credentials source")
  func codexApiTypeReturnsCodexProvider() throws {
    let config = configuration(
      model: "codex-model",
      serverURL: "https://codex.example.com",
      apiKey: nil,
      apiType: "codex",
      reasoningEnabled: true,
      reasoningEffort: "high"
    )

    let provider = try AgentProviderFactory.make(configuration: config)
    #expect(provider is CodexProvider)

    let codexProvider = try #require(provider as? CodexProvider)
    #expect(codexProvider.model == "codex-model")
    #expect(codexProvider.reasoningEnabled == true)
    #expect(codexProvider.reasoningEffort == "high")
    #expect(codexProvider.contextWindow == 128_000)
  }

  // MARK: - Kimi provider

  @Test("kimi apiType with kimi code key and URL returns provider")
  func kimiWithKimiCodeCredentials() throws {
    let config = configuration(
      model: "kimi-model",
      serverURL: KimiK3Support.kimiCodeBaseURL,
      apiKey: "sk-kimi-test-key",
      apiType: "kimi",
      maxTokens: 8192
    )

    let provider = try AgentProviderFactory.make(configuration: config)
    #expect(provider is OpenAICompletionsProvider)

    let completionsProvider = try #require(provider as? OpenAICompletionsProvider)
    #expect(completionsProvider.model == "kimi-model")
    #expect(completionsProvider.requestProfile == .kimiCode)
  }

  @Test("kimi apiType with moonshot key and URL returns provider")
  func kimiWithMoonshotCredentials() throws {
    let config = configuration(
      model: "kimi-model",
      serverURL: KimiK3Support.moonshotBaseURL,
      apiKey: "sk-platform-key",
      apiType: "kimi"
    )

    let provider = try AgentProviderFactory.make(configuration: config)
    #expect(provider is OpenAICompletionsProvider)

    let completionsProvider = try #require(provider as? OpenAICompletionsProvider)
    #expect(completionsProvider.model == "kimi-model")
    #expect(completionsProvider.requestProfile == .moonshotK3)
  }

  @Test("kimi apiType validates maxCompletionTokens")
  func kimiValidatesMaxTokens() {
    let config = configuration(
      model: "kimi-model",
      serverURL: KimiK3Support.moonshotBaseURL,
      apiKey: "sk-platform-key",
      apiType: "kimi",
      maxTokens: 2_000_000  // Way over the limit
    )

    #expect(throws: ScribeError.self) {
      _ = try AgentProviderFactory.make(configuration: config)
    }
  }

  // MARK: - Configuration passthrough

  @Test("contextWindow is propagated to provider")
  func contextWindowPropagated() throws {
    let config = configuration(contextWindow: 50000)
    let provider = try AgentProviderFactory.make(configuration: config)
    let completionsProvider = try #require(provider as? OpenAICompletionsProvider)
    #expect(completionsProvider.contextWindow == 50000)
  }
}
