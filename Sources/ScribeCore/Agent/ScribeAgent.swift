import SystemPackage
import Foundation
import Logging
import ScribeLLM

public struct ScribeAgent: Sendable {

  private let model: String
  private let reasoningEnabled: Bool?

  internal let chatTools: [Components.Schemas.ChatTool]
  private let toolExecutor: any ToolExecutor
  private let client: Client
  private let workingDirectory: FilePath
  private let logger: Logger
  private let abortNotifier = AbortNotifier()

  public init(
    client: Client,
    model: String,
    tools: [any ScribeTool] = [],
    toolExecutor: (any ToolExecutor)? = nil,
    workingDirectory: FilePath,
    reasoningEnabled: Bool?,
    logger: Logger
  ) {
    self.client = client
    self.workingDirectory = workingDirectory
    self.logger = logger
    self.model = model
    self.reasoningEnabled = reasoningEnabled
    if let customExecutor = toolExecutor {
      self.toolExecutor = customExecutor
      self.chatTools = tools.map { type(of: $0).toChatTool(logger: logger) }
    } else {
      let registry = ToolRegistry(tools: tools, logger: logger)
      self.toolExecutor = registry
      self.chatTools = registry.chatTools
    }
  }

  public init(
    configuration: ScribeConfig,
    logger: Logger
  ) throws {
    guard let serverURL = URL(string: configuration.serverURL) else {
      throw ScribeError.configuration(
        key: "serverURL",
        reason: "Invalid serverURL in ScribeConfig: \(configuration.serverURL)")
    }
    let client = OpenAICompatibleClient.make(
      serverURL: serverURL, apiKey: configuration.apiKey)
    self.init(
      client: client,
      model: configuration.agentModel,
      tools: configuration.tools,
      toolExecutor: nil,
      workingDirectory: FilePath(configuration.workingDirectory),
      reasoningEnabled: configuration.reasoningEnabled,
      logger: logger
    )
  }

  public func run(
    _ input: String,
    history: [ScribeMessage],
    options: AgentRunOptions = AgentRunOptions()
  ) -> TurnStream {
    run(
      [ScribeMessage(role: .user, content: input)],
      history: history,
      options: options)
  }

  public func run(
    _ promptMessages: [ScribeMessage],
    history: [ScribeMessage],
    options: AgentRunOptions = AgentRunOptions()
  ) -> TurnStream {
    let wireMessages = promptMessages.toChatMessages()
    let historyWire = history.toChatMessages()
    let (stream, continuation) = AsyncStream<AgentEvent>.makeStream()

    abortNotifier.clear()

    let agentLogger = logger
    let task = Task {
      [
        toolExecutor, chatTools, client, wireMessages, historyWire, options,
        agentLogger, abortNotifier, model, reasoningEnabled, workingDirectory
      ] in
      defer {
        continuation.finish()
      }

      let ctx = AgentContext(messages: historyWire)

      let config = AgentLoopConfig(
        model: model,
        client: client,
        toolExecutor: toolExecutor,
        chatTools: chatTools,
        temperature: options.temperature,
        maxToolRounds: options.maxToolRounds,
        workingDirectory: workingDirectory,
        reasoningEnabled: reasoningEnabled,
        hooks: options.hooks
      )

      do {
        let result = try await runAgentLoop(
          promptMessages: wireMessages,
          context: ctx,
          config: config,
          emit: { continuation.yield($0) },
          logger: agentLogger,
          abortObserver: abortNotifier
        )

        let newMessages = result.messages.toScribeMessages()
        switch result.termination {
        case .completed:
          return TurnResult(newMessages: newMessages, outcome: .completed)
        case .interrupted:
          continuation.yield(.lifecycle(.interrupted))
          return TurnResult(newMessages: newMessages, outcome: .interrupted)
        case .toolRoundLimit(let rounds):
          return TurnResult(
            newMessages: newMessages, outcome: .toolRoundLimit(rounds: rounds))
        }
      } catch is AgentTurnInterruptedError {
        continuation.yield(.lifecycle(.interrupted))

        return TurnResult(newMessages: [], outcome: .interrupted)
      }
    }

    return TurnStream(events: stream, result: task)
  }

  public func abort() {
    abortNotifier.request()
  }
}
