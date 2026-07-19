import Foundation
import Logging
import ScribeLLM
import ScribeLLMAnthropic
import ScribeLLMCodex
import SystemPackage

public struct ScribeAgent: Sendable {

  private let model: String
  private let reasoningEnabled: Bool?

  internal let chatTools: [ScribeLLM.Components.Schemas.ChatTool]
  private let toolExecutor: any ToolExecutor
  private let client: ScribeLLM.Client?
  private let codexClient: ScribeLLMCodex.Client?
  private let codexAccessToken: String?
  private let codexAccountID: String?
  private let anthropicClient: ScribeLLMAnthropic.Client?
  private let anthropicSystemPrompt: String?
  private let anthropicMaxTokens: Int
  private let workingDirectory: FilePath
  private let logger: Logger
  private let abortNotifier = AbortNotifier()

  // Lazy codex init from config
  private let _isCodexConfig: Bool
  private let _codexServerURL: URL?

  // Lazy anthropic init from config
  private let _isAnthropicConfig: Bool
  private let _anthropicServerURL: URL?

  private let _requestProfile: ChatCompletionRequestProfile
  private let _maxCompletionTokens: Int?

  /// Standard (OpenAI-compatible) initializer.
  public init(
    client: ScribeLLM.Client,
    model: String,
    tools: [any ScribeTool] = [],
    toolExecutor: (any ToolExecutor)? = nil,
    workingDirectory: FilePath,
    reasoningEnabled: Bool?,
    logger: Logger
  ) {
    self.client = client
    self.codexClient = nil
    self.codexAccessToken = nil
    self.codexAccountID = nil
    self.anthropicClient = nil
    self.anthropicSystemPrompt = nil
    self.anthropicMaxTokens = 8192
    self.workingDirectory = workingDirectory
    self.logger = logger
    self.model = model
    self.reasoningEnabled = reasoningEnabled
    self._isCodexConfig = false
    self._codexServerURL = nil
    self._isAnthropicConfig = false
    self._anthropicServerURL = nil
    self._requestProfile = .standard
    self._maxCompletionTokens = nil
    if let customExecutor = toolExecutor {
      self.toolExecutor = customExecutor
      self.chatTools = tools.map { type(of: $0).toChatTool(logger: logger) }
    } else {
      let registry = ToolRegistry(tools: tools, logger: logger)
      self.toolExecutor = registry
      self.chatTools = registry.chatTools
    }
  }

  /// Codex (ChatGPT subscription) initializer.
  public init(
    codexClient: ScribeLLMCodex.Client,
    accessToken: String,
    accountID: String,
    model: String,
    tools: [any ScribeTool] = [],
    toolExecutor: (any ToolExecutor)? = nil,
    workingDirectory: FilePath,
    reasoningEnabled: Bool?,
    logger: Logger
  ) {
    self.client = nil
    self.codexClient = codexClient
    self.codexAccessToken = accessToken
    self.codexAccountID = accountID
    self.anthropicClient = nil
    self.anthropicSystemPrompt = nil
    self.anthropicMaxTokens = 8192
    self.workingDirectory = workingDirectory
    self.logger = logger
    self.model = model
    self.reasoningEnabled = reasoningEnabled
    self._isCodexConfig = false
    self._codexServerURL = nil
    self._isAnthropicConfig = false
    self._anthropicServerURL = nil
    self._requestProfile = .standard
    self._maxCompletionTokens = nil
    if let customExecutor = toolExecutor {
      self.toolExecutor = customExecutor
      self.chatTools = tools.map { type(of: $0).toChatTool(logger: logger) }
    } else {
      let registry = ToolRegistry(tools: tools, logger: logger)
      self.toolExecutor = registry
      self.chatTools = registry.chatTools
    }
  }

  /// Anthropic Messages-compatible initializer.
  public init(
    anthropicClient: ScribeLLMAnthropic.Client,
    model: String,
    tools: [any ScribeTool] = [],
    toolExecutor: (any ToolExecutor)? = nil,
    workingDirectory: FilePath,
    reasoningEnabled: Bool?,
    systemPrompt: String? = nil,
    maxTokens: Int = 8192,
    logger: Logger
  ) {
    self.client = nil
    self.codexClient = nil
    self.codexAccessToken = nil
    self.codexAccountID = nil
    self.anthropicClient = anthropicClient
    self.anthropicSystemPrompt = systemPrompt
    self.anthropicMaxTokens = maxTokens
    self.workingDirectory = workingDirectory
    self.logger = logger
    self.model = model
    self.reasoningEnabled = reasoningEnabled
    self._isCodexConfig = false
    self._codexServerURL = nil
    self._isAnthropicConfig = false
    self._anthropicServerURL = nil
    self._requestProfile = .standard
    self._maxCompletionTokens = nil
    if let customExecutor = toolExecutor {
      self.toolExecutor = customExecutor
      self.chatTools = tools.map { type(of: $0).toChatTool(logger: logger) }
    } else {
      let registry = ToolRegistry(tools: tools, logger: logger)
      self.toolExecutor = registry
      self.chatTools = registry.chatTools
    }
  }

  /// Create from ScribeConfig, auto-detecting standard vs codex vs anthropic vs kimi.
  /// Codex credentials are loaded lazily on first `run()`.
  public init(
    configuration: ScribeConfig,
    logger: Logger
  ) throws {
    let registry = ToolRegistry(tools: configuration.tools, logger: logger)
    self.toolExecutor = registry
    self.chatTools = registry.chatTools
    self.workingDirectory = FilePath(configuration.workingDirectory)
    self.logger = logger
    self.model = configuration.agentModel
    self.reasoningEnabled = configuration.reasoningEnabled
    self.anthropicSystemPrompt = nil
    self.anthropicMaxTokens = configuration.maxTokens ?? 8192

    if configuration.apiType == "codex" {
      guard let serverURL = URL(string: configuration.serverURL) else {
        throw ScribeError.configuration(
          key: "serverURL",
          reason: "Invalid serverURL: \(configuration.serverURL)")
      }
      self.client = nil
      self.codexClient = nil
      self.codexAccessToken = nil
      self.codexAccountID = nil
      self.anthropicClient = nil
      self._isCodexConfig = true
      self._codexServerURL = serverURL
      self._isAnthropicConfig = false
      self._anthropicServerURL = nil
      self._requestProfile = .standard
      self._maxCompletionTokens = nil
    } else if configuration.apiType == "kimi" {
      guard let serverURL = URL(string: configuration.serverURL) else {
        throw ScribeError.configuration(
          key: "serverURL",
          reason: "Invalid serverURL: \(configuration.serverURL)")
      }
      let transport = try KimiK3Support.resolveTransport(
        apiKey: configuration.apiKey,
        serverURL: configuration.serverURL
      )
      switch transport {
      case .moonshotOpenAI:
        try KimiK3Support.validateMaxCompletionTokens(configuration.maxTokens)
        self.client = OpenAICompatibleClient.make(
          serverURL: serverURL, apiKey: configuration.apiKey)
        self.anthropicClient = nil
        self._requestProfile = .kimiK3
        self._maxCompletionTokens = configuration.maxTokens
      case .kimiCodeAnthropic:
        self.client = nil
        self.anthropicClient = KimiCodeClient.make(
          serverURL: serverURL, token: configuration.apiKey)
        self._requestProfile = .standard
        self._maxCompletionTokens = nil
      }
      self.codexClient = nil
      self.codexAccessToken = nil
      self.codexAccountID = nil
      self._isCodexConfig = false
      self._codexServerURL = nil
      self._isAnthropicConfig = false
      self._anthropicServerURL = nil
    } else if configuration.apiType == "anthropic" {
      guard let serverURL = URL(string: configuration.serverURL) else {
        throw ScribeError.configuration(
          key: "serverURL",
          reason: "Invalid serverURL: \(configuration.serverURL)")
      }
      self.client = nil
      self.codexClient = nil
      self.codexAccessToken = nil
      self.codexAccountID = nil
      self.anthropicClient = AnthropicClient.make(
        serverURL: serverURL, apiKey: configuration.apiKey)
      self._isCodexConfig = false
      self._codexServerURL = nil
      self._isAnthropicConfig = false
      self._anthropicServerURL = nil
      self._requestProfile = .standard
      self._maxCompletionTokens = nil
    } else {
      guard let serverURL = URL(string: configuration.serverURL) else {
        throw ScribeError.configuration(
          key: "serverURL",
          reason: "Invalid serverURL: \(configuration.serverURL)")
      }
      self.client = OpenAICompatibleClient.make(
        serverURL: serverURL, apiKey: configuration.apiKey)
      self.codexClient = nil
      self.codexAccessToken = nil
      self.codexAccountID = nil
      self.anthropicClient = nil
      self._isCodexConfig = false
      self._codexServerURL = nil
      self._isAnthropicConfig = false
      self._anthropicServerURL = nil
      self._requestProfile = .standard
      self._maxCompletionTokens = nil
    }
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

    // Resolve effective codex client (lazy init from config)
    let effectiveCodexClient: ScribeLLMCodex.Client?
    let effectiveAccessToken: String?
    let effectiveAccountID: String?

    if _isCodexConfig, let serverURL = _codexServerURL {
      do {
        let cred = try CodexOAuth.loadCredentialsSync()
        effectiveCodexClient = OpenAICodexClient.make(
          serverURL: serverURL,
          accessToken: cred.access,
          accountID: cred.accountId
        )
        effectiveAccessToken = cred.access
        effectiveAccountID = cred.accountId
      } catch {
        let task = Task<TurnResult, Error> {
          defer { continuation.finish() }
          continuation.yield(.lifecycle(.error(.generic("Codex credentials not found. Run `scribe --login` first."))))
          return TurnResult(newMessages: [], outcome: .error("Not logged in"))
        }
        return TurnStream(events: stream, result: task)
      }
    } else {
      effectiveCodexClient = codexClient
      effectiveAccessToken = codexAccessToken
      effectiveAccountID = codexAccountID
    }

    // Codex path
    if let codexClient = effectiveCodexClient,
       let accessToken = effectiveAccessToken,
       let accountID = effectiveAccountID {
      let task = Task<TurnResult, Error> {
        [
          toolExecutor, chatTools, codexClient, accessToken, accountID,
          wireMessages, historyWire, options, agentLogger, abortNotifier,
          model, reasoningEnabled, workingDirectory
        ] in
        defer { continuation.finish() }

        let ctx = AgentContext(messages: historyWire)

        let config = CodexAgentLoopConfig(
          model: model,
          client: codexClient,
          accessToken: accessToken,
          accountID: accountID,
          toolExecutor: toolExecutor,
          chatTools: chatTools,
          maxToolRounds: options.maxToolRounds,
          workingDirectory: workingDirectory,
          reasoningEnabled: reasoningEnabled,
          hooks: .default
        )

        do {
          let result = try await runCodexAgentLoop(
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
          case .incomplete(let reason):
            continuation.yield(.lifecycle(.error(.generic("Response incomplete\(reason.map { ": \($0)" } ?? "")"))))
            return TurnResult(newMessages: newMessages, outcome: .incomplete(reason: reason))
          case .interrupted:
            continuation.yield(.lifecycle(.interrupted))
            return TurnResult(newMessages: newMessages, outcome: .interrupted)
          case .toolRoundLimit(let rounds):
            return TurnResult(newMessages: newMessages, outcome: .toolRoundLimit(rounds: rounds))
          case .error(let desc):
            continuation.yield(.lifecycle(.error(.generic(desc))))
            return TurnResult(newMessages: newMessages, outcome: .error(desc))
          }
        } catch is AgentTurnInterruptedError {
          continuation.yield(.lifecycle(.interrupted))
          return TurnResult(newMessages: [], outcome: .interrupted)
        }
      }

      return TurnStream(events: stream, result: task)
    }

    // Anthropic path
    if let anthropicClient = anthropicClient {
      let task = Task<TurnResult, Error> {
        [
          toolExecutor, chatTools, anthropicClient, wireMessages, historyWire, options,
          agentLogger, abortNotifier, model, reasoningEnabled, workingDirectory,
          anthropicSystemPrompt, anthropicMaxTokens
        ] in
        defer { continuation.finish() }

        let ctx = AgentContext(messages: historyWire)

        let config = AnthropicAgentLoopConfig(
          model: model,
          client: anthropicClient,
          toolExecutor: toolExecutor,
          chatTools: chatTools,
          maxToolRounds: options.maxToolRounds,
          workingDirectory: workingDirectory,
          reasoningEnabled: reasoningEnabled,
          hooks: .default,
          systemPrompt: anthropicSystemPrompt,
          maxTokens: anthropicMaxTokens
        )

        do {
          let result = try await runAnthropicAgentLoop(
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
          case .incomplete(let reason):
            continuation.yield(.lifecycle(.error(.generic("Response incomplete\(reason.map { ": \($0)" } ?? "")"))))
            return TurnResult(newMessages: newMessages, outcome: .incomplete(reason: reason))
          case .interrupted:
            continuation.yield(.lifecycle(.interrupted))
            return TurnResult(newMessages: newMessages, outcome: .interrupted)
          case .toolRoundLimit(let rounds):
            return TurnResult(newMessages: newMessages, outcome: .toolRoundLimit(rounds: rounds))
          case .error(let desc):
            continuation.yield(.lifecycle(.error(.generic(desc))))
            return TurnResult(newMessages: newMessages, outcome: .error(desc))
          }
        } catch is AgentTurnInterruptedError {
          continuation.yield(.lifecycle(.interrupted))
          return TurnResult(newMessages: [], outcome: .interrupted)
        }
      }

      return TurnStream(events: stream, result: task)
    }

    // Standard path
    guard let client = client else {
      let task = Task<TurnResult, Error> {
        defer { continuation.finish() }
        return TurnResult(newMessages: [], outcome: .error("No client configured"))
      }
      return TurnStream(events: stream, result: task)
    }

    let task = Task<TurnResult, Error> {
      [
        toolExecutor, chatTools, client, wireMessages, historyWire, options,
        agentLogger, abortNotifier, model, reasoningEnabled, workingDirectory
      ] in
      defer { continuation.finish() }

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
        hooks: .default,
        requestProfile: _requestProfile,
        maxCompletionTokens: _maxCompletionTokens
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
        case .incomplete(let reason):
          continuation.yield(.lifecycle(.error(.generic("Response incomplete\(reason.map { ": \($0)" } ?? "")"))))
          return TurnResult(newMessages: newMessages, outcome: .incomplete(reason: reason))
        case .interrupted:
          continuation.yield(.lifecycle(.interrupted))
          return TurnResult(newMessages: newMessages, outcome: .interrupted)
        case .toolRoundLimit(let rounds):
          return TurnResult(newMessages: newMessages, outcome: .toolRoundLimit(rounds: rounds))
        case .error(let desc):
          continuation.yield(.lifecycle(.error(.generic(desc))))
          return TurnResult(newMessages: newMessages, outcome: .error(desc))
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
