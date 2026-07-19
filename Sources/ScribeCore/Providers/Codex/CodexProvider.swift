import Foundation
import Logging
import ScribeCodexAuth
import ScribeLLM
import ScribeLLMCodex
import SystemPackage

struct CodexProvider: AgentProvider {
  enum ClientSource: Sendable {
    case configured(ScribeLLMCodex.Client)
    case credentials(serverURL: URL)
  }

  let source: ClientSource
  let model: String
  let reasoningEnabled: Bool?
  let contextWindow: Int

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

      let client: ScribeLLMCodex.Client
      switch source {
      case .configured(let configuredClient):
        client = configuredClient
      case .credentials(let serverURL):
        let credential: CodexCredential
        do {
          credential = try await CodexOAuth.getValidCredentials()
        } catch {
          let message = "Codex credentials not found. Run `scribe --login openai` first."
          continuation.yield(.lifecycle(.error(.generic(message))))
          return TurnResult(newMessages: [], outcome: .error("Not logged in"))
        }
        client = OpenAICodexClient.make(
          serverURL: serverURL,
          accessToken: credential.access,
          accountID: credential.accountId)
      }

      let config = CodexAgentLoopConfig(
        model: model,
        client: client,
        toolExecutor: toolExecutor,
        chatTools: chatTools,
        maxToolRounds: options.maxToolRounds,
        workingDirectory: workingDirectory,
        reasoningEnabled: reasoningEnabled,
        hooks: .default,
        contextWindow: contextWindow
      )

      do {
        let result = try await runCodexAgentLoop(
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
