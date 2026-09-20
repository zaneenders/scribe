import Foundation
import ScribeLLM

extension AgentProvider where Self == OpenAICompletionsProvider {
  static func openAICompletions(
    client: ScribeLLM.Client,
    model: String,
    reasoningEnabled: Bool?,
    reasoningEncoding: ReasoningEncoding = .openRouter,
    reasoningEffort: String? = nil,
    contextWindow: Int = 0,
    sendsOpenCodeHeader: Bool = false
  ) -> Self {
    OpenAICompletionsProvider(
      client: client,
      model: model,
      reasoningEnabled: reasoningEnabled,
      reasoningEncoding: reasoningEncoding,
      reasoningEffort: reasoningEffort,
      contextWindow: contextWindow,
      sendsOpenCodeHeader: sendsOpenCodeHeader)
  }
}

enum AgentProviderFactory {
  static func make(configuration: ScribeConfig) throws -> any AgentProvider {
    guard let serverURL = URL(string: configuration.serverURL) else {
      throw ScribeError.configuration(
        key: "serverURL",
        reason: "Invalid serverURL: \(configuration.serverURL)")
    }

    let retryPolicy =
      configuration.maxRetries.map { RetryPolicy(maxRetries: $0) } ?? .default

    switch configuration.apiType {
    case "codex":
      return CodexProvider(
        source: .credentials(serverURL: serverURL),
        model: configuration.agentModel,
        reasoningEnabled: configuration.reasoningEnabled,
        reasoningEffort: configuration.reasoningEffort,
        serviceTier: configuration.serviceTier,
        defaultTemperature: configuration.temperature,
        contextWindow: configuration.contextWindow,
        retryPolicy: retryPolicy)

    default:
      return OpenAICompletionsProvider(
        client: OpenAICompatibleClient.make(
          serverURL: serverURL,
          apiKey: configuration.apiKey),
        model: configuration.agentModel,
        reasoningEnabled: configuration.reasoningEnabled,
        reasoningEncoding: configuration.apiType == "deepseek" ? .deepSeek : .openRouter,
        reasoningEffort: configuration.reasoningEffort,
        contextWindow: configuration.contextWindow,
        sendsOpenCodeHeader: configuration.sendsOpenCodeHeader,
        defaultTemperature: configuration.temperature ?? 0,
        retryPolicy: retryPolicy)
    }
  }
}
