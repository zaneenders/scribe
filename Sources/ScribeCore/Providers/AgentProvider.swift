import Logging
import ScribeLLM
import SystemPackage

/// Provider boundary between the agent facade and model-specific transports.
protocol AgentProvider: Sendable {
  func run(
    promptMessages: [Components.Schemas.ChatMessage],
    history: [Components.Schemas.ChatMessage],
    options: AgentRunOptions,
    toolExecutor: any ToolExecutor,
    chatTools: [Components.Schemas.ChatTool],
    workingDirectory: FilePath,
    logger: Logger,
    abortNotifier: AbortNotifier
  ) -> TurnStream
}

func turnResult(
  messages: [Components.Schemas.ChatMessage],
  outcome: TurnOutcome,
  emit: @escaping @Sendable (AgentEvent) -> Void
) -> TurnResult {
  let newMessages = messages.toScribeMessages()
  switch outcome {
  case .completed:
    return TurnResult(newMessages: newMessages, outcome: .completed)
  case .incomplete(let reason):
    emit(.lifecycle(.error(.generic("Response incomplete\(reason.map { ": \($0)" } ?? "")"))))
    return TurnResult(newMessages: newMessages, outcome: .incomplete(reason: reason))
  case .interrupted:
    emit(.lifecycle(.interrupted))
    return TurnResult(newMessages: newMessages, outcome: .interrupted)
  case .toolRoundLimit(let rounds):
    return TurnResult(newMessages: newMessages, outcome: .toolRoundLimit(rounds: rounds))
  case .error(let description):
    emit(.lifecycle(.error(.generic(description))))
    return TurnResult(newMessages: newMessages, outcome: .error(description))
  }
}
