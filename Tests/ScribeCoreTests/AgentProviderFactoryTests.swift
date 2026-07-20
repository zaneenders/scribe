import Foundation
import Testing

@testable import ScribeCore

@Suite
struct AgentProviderFactoryTests {

    // MARK: - Invalid server URL

    @Test("throws on empty serverURL")
    func throwsOnEmptyServerURL() {
        let config = ScribeConfig(
            agentModel: "gpt-4o",
            contextWindow: 128000,
            contextWindowThreshold: 0.75,
            serverURL: "",
            apiKey: "sk-test",
            apiType: "openai",
            workingDirectory: "/tmp",
            reasoningEnabled: nil
        )

        #expect(throws: ScribeError.self) {
            _ = try AgentProviderFactory.make(configuration: config)
        }
    }

    // MARK: - Codex provider

    @Test("codex apiType returns CodexProvider with credentials source")
    func codexApiTypeReturnsCodexProvider() throws {
        let config = ScribeConfig(
            agentModel: "codex-model",
            contextWindow: 128000,
            contextWindowThreshold: 0.75,
            serverURL: "https://codex.example.com",
            apiKey: nil,
            apiType: "codex",
            workingDirectory: "/tmp",
            reasoningEnabled: true,
            reasoningEffort: "high"
        )

        let provider = try AgentProviderFactory.make(configuration: config)
        #expect(provider is CodexProvider)

        let codexProvider = provider as! CodexProvider
        #expect(codexProvider.model == "codex-model")
        #expect(codexProvider.reasoningEnabled == true)
        #expect(codexProvider.reasoningEffort == "high")
        #expect(codexProvider.contextWindow == 128000)
    }

    // MARK: - Kimi provider

    @Test("kimi apiType with kimi code key and URL returns provider")
    func kimiWithKimiCodeCredentials() throws {
        let config = ScribeConfig(
            agentModel: "kimi-model",
            contextWindow: 128000,
            contextWindowThreshold: 0.75,
            serverURL: KimiK3Support.kimiCodeBaseURL,
            apiKey: "sk-kimi-test-key",
            apiType: "kimi",
            workingDirectory: "/tmp",
            reasoningEnabled: nil,
            maxTokens: 8192
        )

        let provider = try AgentProviderFactory.make(configuration: config)
        #expect(provider is OpenAICompletionsProvider)

        let completionsProvider = provider as! OpenAICompletionsProvider
        #expect(completionsProvider.model == "kimi-model")
        #expect(completionsProvider.requestProfile == .kimiCode)
    }

    @Test("kimi apiType with moonshot key and URL returns provider")
    func kimiWithMoonshotCredentials() throws {
        let config = ScribeConfig(
            agentModel: "kimi-model",
            contextWindow: 128000,
            contextWindowThreshold: 0.75,
            serverURL: KimiK3Support.moonshotBaseURL,
            apiKey: "sk-platform-key",
            apiType: "kimi",
            workingDirectory: "/tmp",
            reasoningEnabled: nil
        )

        let provider = try AgentProviderFactory.make(configuration: config)
        #expect(provider is OpenAICompletionsProvider)

        let completionsProvider = provider as! OpenAICompletionsProvider
        #expect(completionsProvider.model == "kimi-model")
        #expect(completionsProvider.requestProfile == .moonshotK3)
    }

    @Test("kimi apiType validates maxCompletionTokens")
    func kimiValidatesMaxTokens() {
        let config = ScribeConfig(
            agentModel: "kimi-model",
            contextWindow: 128000,
            contextWindowThreshold: 0.75,
            serverURL: KimiK3Support.moonshotBaseURL,
            apiKey: "sk-platform-key",
            apiType: "kimi",
            workingDirectory: "/tmp",
            reasoningEnabled: nil,
            maxTokens: 2_000_000  // Way over the limit
        )

        #expect(throws: ScribeError.self) {
            _ = try AgentProviderFactory.make(configuration: config)
        }
    }

    // MARK: - Default / OpenAI provider

    @Test("default apiType returns OpenAICompletionsProvider")
    func defaultApiTypeReturnsOpenAICompletionsProvider() throws {
        let config = ScribeConfig(
            agentModel: "gpt-4o",
            contextWindow: 128000,
            contextWindowThreshold: 0.75,
            serverURL: "https://api.openai.com",
            apiKey: "sk-openai-key",
            apiType: nil,
            workingDirectory: "/tmp",
            reasoningEnabled: nil
        )

        let provider = try AgentProviderFactory.make(configuration: config)
        #expect(provider is OpenAICompletionsProvider)

        let completionsProvider = provider as! OpenAICompletionsProvider
        #expect(completionsProvider.model == "gpt-4o")
        #expect(completionsProvider.requestProfile == .standard)
    }

    @Test("unknown apiType string returns OpenAICompletionsProvider as default")
    func unknownApiTypeDefaults() throws {
        let config = ScribeConfig(
            agentModel: "some-model",
            contextWindow: 16384,
            contextWindowThreshold: 0.75,
            serverURL: "https://custom-llm.example.com",
            apiKey: "sk-key",
            apiType: "some-unknown-type",
            workingDirectory: "/tmp",
            reasoningEnabled: nil
        )

        let provider = try AgentProviderFactory.make(configuration: config)
        #expect(provider is OpenAICompletionsProvider)
    }

    @Test("openai apiType explicitly returns OpenAICompletionsProvider")
    func openaiApiTypeExplicit() throws {
        let config = ScribeConfig(
            agentModel: "gpt-4o-mini",
            contextWindow: 128000,
            contextWindowThreshold: 0.75,
            serverURL: "https://api.openai.com",
            apiKey: "sk-key",
            apiType: "openai",
            workingDirectory: "/tmp",
            reasoningEnabled: false
        )

        let provider = try AgentProviderFactory.make(configuration: config)
        #expect(provider is OpenAICompletionsProvider)

        let completionsProvider = provider as! OpenAICompletionsProvider
        #expect(completionsProvider.reasoningEnabled == false)
    }

    // MARK: - Configuration passthrough

    @Test("contextWindow is propagated to provider")
    func contextWindowPropagated() throws {
        let config = ScribeConfig(
            agentModel: "model",
            contextWindow: 50000,
            contextWindowThreshold: 0.75,
            serverURL: "https://api.example.com",
            apiKey: "sk-key",
            apiType: nil,
            workingDirectory: "/tmp",
            reasoningEnabled: nil
        )

        let provider = try AgentProviderFactory.make(configuration: config)
        let completionsProvider = provider as! OpenAICompletionsProvider
        #expect(completionsProvider.contextWindow == 50000)
    }

    @Test("maxCompletionTokens nil is propagated to provider")
    func maxTokensNilPropagated() throws {
        let config = ScribeConfig(
            agentModel: "model",
            contextWindow: 128000,
            contextWindowThreshold: 0.75,
            serverURL: "https://api.example.com",
            apiKey: "sk-key",
            apiType: nil,
            workingDirectory: "/tmp",
            reasoningEnabled: nil,
            maxTokens: nil
        )

        let provider = try AgentProviderFactory.make(configuration: config)
        let completionsProvider = provider as! OpenAICompletionsProvider
        #expect(completionsProvider.maxCompletionTokens == nil)
    }
}
