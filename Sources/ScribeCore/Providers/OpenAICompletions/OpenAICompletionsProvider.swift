import Logging
import ScribeLLM
import SystemPackage

struct OpenAICompletionsProvider: AgentProvider {
  let client: ScribeLLM.Client
  let model: String
  let reasoningEnabled: Bool?
  let contextWindow: Int
  let requestProfile: ChatCompletionRequestProfile
  let maxCompletionTokens: Int?
  var retryPolicy: RetryPolicy = .default

  func run(
    promptMessages: [Components.Schemas.ChatMessage],
    history: [Components.Schemas.ChatMessage],
    options: AgentRunOptions,
    toolExecutor: any ToolExecutor,
    chatTools: [Components.Schemas.ChatTool],
    workingDirectory: FilePath,
    logger: Logger,
    abortNotifier: AbortNotifier
  ) -> TurnStream {
    let (stream, continuation) = AsyncStream<AgentEvent>.makeStream()
    let config = AgentLoopConfig(
      model: model,
      client: client,
      toolExecutor: toolExecutor,
      chatTools: chatTools,
      temperature: options.temperature,
      maxToolRounds: options.maxToolRounds,
      workingDirectory: workingDirectory,
      reasoningEnabled: reasoningEnabled,
      hooks: .default,
      requestProfile: requestProfile,
      maxCompletionTokens: maxCompletionTokens,
      contextWindow: contextWindow,
      retryPolicy: retryPolicy
    )

    let task = Task<TurnResult, Error> {
      defer { continuation.finish() }
      do {
        let result = try await runAgentLoop(
          promptMessages: promptMessages,
          context: AgentContext(messages: history),
          config: config,
          emit: { continuation.yield($0) },
          logger: logger,
          abortObserver: abortNotifier
        )
        return turnResult(
          messages: result.messages,
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
