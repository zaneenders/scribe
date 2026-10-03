import Logging
import ScribeCodexAuth
import ScribeLLM
import ScribeLLMResponses
import SystemPackage

public struct ScribeAgent: Sendable {
  internal let chatTools: [ScribeLLM.Components.Schemas.ChatTool]
  public var toolNames: [String] { chatTools.map { $0.function.name } }
  private let toolExecutor: any ToolExecutor
  private let provider: any AgentProvider
  private let workingDirectory: FilePath
  private let logger: Logger
  private let abortNotifier = AbortNotifier()

  public init(
    client: ScribeLLM.Client,
    model: String,
    tools: [any ScribeTool] = [],
    toolExecutor: (any ToolExecutor)? = nil,
    workingDirectory: FilePath,
    reasoningEnabled: Bool?,
    contextWindow: Int = 0,
    logger: Logger
  ) {
    let prepared = Self.prepareTools(tools, executor: toolExecutor, logger: logger)
    self.toolExecutor = prepared.executor
    self.chatTools = prepared.chatTools
    self.provider = OpenAICompletionsProvider.openAICompletions(
      client: client,
      model: model,
      reasoningEnabled: reasoningEnabled,
      contextWindow: contextWindow)
    self.workingDirectory = workingDirectory
    self.logger = logger
  }

  public init(
    responsesClient: ScribeLLMResponses.Client,
    model: String,
    tools: [any ScribeTool] = [],
    toolExecutor: (any ToolExecutor)? = nil,
    workingDirectory: FilePath,
    reasoningEnabled: Bool?,
    contextWindow: Int = 0,
    logger: Logger
  ) {
    let prepared = Self.prepareTools(tools, executor: toolExecutor, logger: logger)
    self.toolExecutor = prepared.executor
    self.chatTools = prepared.chatTools
    self.provider = ResponsesProvider(
      source: .configured(responsesClient),
      model: model,
      reasoningEnabled: reasoningEnabled,
      reasoningEffort: nil,
      contextWindow: contextWindow)
    self.workingDirectory = workingDirectory
    self.logger = logger
  }

  public init(configuration: ScribeConfig, logger: Logger, codexCredentials: (any CodexAccessCredentialProvider)? = nil)
    throws
  {
    let registry = ToolRegistry(tools: configuration.tools, logger: logger)
    self.toolExecutor = registry
    self.chatTools = registry.chatTools
    self.provider = try AgentProviderFactory.make(
      configuration: configuration, codexCredentials: codexCredentials ?? configuration.codexCredentials)
    self.workingDirectory = FilePath(configuration.workingDirectory)
    self.logger = logger
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
    abortNotifier.clear()
    return provider.run(
      promptMessages: promptMessages.toChatMessages(),
      history: history.toChatMessages(),
      options: options,
      toolExecutor: toolExecutor,
      chatTools: chatTools,
      workingDirectory: workingDirectory,
      logger: logger,
      abortNotifier: abortNotifier)
  }

  public func abort() {
    abortNotifier.request()
  }

  private static func prepareTools(
    _ tools: [any ScribeTool],
    executor: (any ToolExecutor)?,
    logger: Logger
  ) -> (executor: any ToolExecutor, chatTools: [ScribeLLM.Components.Schemas.ChatTool]) {
    if let executor {
      return (executor, tools.map { type(of: $0).toChatTool(logger: logger) })
    }
    let registry = ToolRegistry(tools: tools, logger: logger)
    return (registry, registry.chatTools)
  }
}
