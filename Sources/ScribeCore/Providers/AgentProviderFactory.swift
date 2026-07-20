import Foundation
import ScribeLLM

extension AgentProvider where Self == OpenAICompletionsProvider {
  static func openAICompletions(
    client: ScribeLLM.Client,
    model: String,
    reasoningEnabled: Bool?,
    contextWindow: Int = 0
  ) -> Self {
    OpenAICompletionsProvider(
      client: client,
      model: model,
      reasoningEnabled: reasoningEnabled,
      contextWindow: contextWindow,
      requestProfile: .standard,
      maxCompletionTokens: nil)
  }
}

enum AgentProviderFactory {
  static func make(configuration: ScribeConfig) throws -> any AgentProvider {
    guard let serverURL = URL(string: configuration.serverURL) else {
      throw ScribeError.configuration(
        key: "serverURL",
        reason: "Invalid serverURL: \(configuration.serverURL)")
    }

    switch configuration.apiType {
    case "codex":
      return CodexProvider(
        source: .credentials(serverURL: serverURL),
        model: configuration.agentModel,
        reasoningEnabled: configuration.reasoningEnabled,
        contextWindow: configuration.contextWindow)

    case "kimi":
      let transport = try KimiK3Support.resolveTransport(
        apiKey: configuration.apiKey,
        serverURL: configuration.serverURL)
      try KimiK3Support.validateMaxCompletionTokens(configuration.maxTokens)

      let client: ScribeLLM.Client
      let profile: ChatCompletionRequestProfile
      switch transport {
      case .moonshotOpenAI:
        client = OpenAICompatibleClient.make(
          serverURL: serverURL,
          apiKey: configuration.apiKey)
        profile = .moonshotK3
      case .kimiCodeOpenAI:
        client = OpenAICompatibleClient.makeForKimiCode(
          serverURL: serverURL,
          apiKey: configuration.apiKey,
          headers: KimiCodeIdentity.requestHeaders())
        profile = .kimiCode
      }
      return OpenAICompletionsProvider(
        client: client,
        model: configuration.agentModel,
        reasoningEnabled: configuration.reasoningEnabled,
        contextWindow: configuration.contextWindow,
        requestProfile: profile,
        maxCompletionTokens: configuration.maxTokens)

    default:
      return OpenAICompletionsProvider(
        client: OpenAICompatibleClient.make(
          serverURL: serverURL,
          apiKey: configuration.apiKey),
        model: configuration.agentModel,
        reasoningEnabled: configuration.reasoningEnabled,
        contextWindow: configuration.contextWindow,
        requestProfile: .standard,
        maxCompletionTokens: nil)
    }
  }
}
