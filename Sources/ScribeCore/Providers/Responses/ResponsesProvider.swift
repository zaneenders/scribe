import Foundation
import Logging
import ScribeCodexAuth
import ScribeLLM
import ScribeLLMResponses
import SystemPackage

struct ResponsesProvider: AgentProvider {
  enum ClientSource: Sendable {
    case configured(ScribeLLMResponses.Client)
    case credentials(serverURL: URL)
  }

  let source: ClientSource
  let model: String
  let reasoningEnabled: Bool?
  let reasoningEffort: String?
  var serviceTier: String? = nil
  var defaultTemperature: Double? = nil
  let contextWindow: Int
  var usesCodexBackend = true
  var retryPolicy: RetryPolicy = .default

  func run(
    promptMessages: [ScribeLLM.Components.Schemas.ChatMessage],
    history: [ScribeLLM.Components.Schemas.ChatMessage],
    options: AgentRunOptions,
    toolExecutor: any ToolExecutor,
    chatTools: [ScribeLLM.Components.Schemas.ChatTool],
    workingDirectory: FilePath,
    logger: Logger,
    abortNotifier: AbortNotifier
  ) -> TurnStream {
    let (stream, continuation) = AsyncStream<AgentEvent>.makeStream()
    let task = Task<TurnResult, Error> {
      defer { continuation.finish() }

      let client: ScribeLLMResponses.Client
      switch source {
      case .configured(let configuredClient):
        client = configuredClient
      case .credentials(let serverURL):
        client = ResponsesClient.makeAuthenticated(serverURL: serverURL)
      }

      let config = ResponsesAgentLoopConfig(
        model: model,
        client: client,
        toolExecutor: toolExecutor,
        chatTools: chatTools,
        maxToolRounds: options.maxToolRounds,
        workingDirectory: workingDirectory,
        reasoningEnabled: reasoningEnabled,
        reasoningEffort: reasoningEffort,
        serviceTier: serviceTier,
        usesCodexBackend: usesCodexBackend,
        temperature: options.temperature ?? defaultTemperature,
        hooks: AgentLoopHooks(onMessagesCommitted: options.onMessagesCommitted),
        contextWindow: contextWindow,
        retryPolicy: retryPolicy
      )

      do {
        let result = try await runResponsesAgentLoop(
          promptMessages: promptMessages,
          context: AgentContext(messages: history),
          config: config,
          emit: { continuation.yield($0) },
          logger: logger,
          abortObserver: abortNotifier
        )
        return turnResult(
          messages: result.transcriptMessages,
          outcome: result.termination,
          emit: { continuation.yield($0) })
      } catch is AgentTurnInterruptedError {
        continuation.yield(.lifecycle(.interrupted))
        return TurnResult(newMessages: [], outcome: .interrupted)
      }
    }
    return TurnStream(events: stream, result: task)
  }
}
