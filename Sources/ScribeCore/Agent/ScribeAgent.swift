import Foundation
import Logging
import ScribeLLM

public struct ScribeAgent: Sendable {

  private actor Storage {
    var systemPrompt: String
    var model: String
    var messages: [Components.Schemas.ChatMessage]
    var isStreaming = false

    init(
      systemPrompt: String,
      model: String,
      messages: [Components.Schemas.ChatMessage]
    ) {
      self.systemPrompt = systemPrompt
      self.model = model
      self.messages = messages
    }

    func snapshot() -> AgentStateSnapshot {
      AgentStateSnapshot(
        systemPrompt: systemPrompt,
        model: model,
        messages: messages,
        isStreaming: isStreaming
      )
    }

    func appendMessages(_ newMessages: [Components.Schemas.ChatMessage]) {
      messages.append(contentsOf: newMessages)
    }

    func messages(since start: Int) -> [Components.Schemas.ChatMessage] {
      guard start < messages.count else { return [] }
      let clamped = max(start, 0)
      return Array(messages[clamped...])
    }

    func messages(in range: Range<Int>) -> [Components.Schemas.ChatMessage] {
      let lower = max(0, range.lowerBound)
      let upper = min(messages.count, range.upperBound)
      guard lower < upper else { return [] }
      return Array(messages[lower..<upper])
    }

    func setStreaming(_ value: Bool) { isStreaming = value }
  }

  private let storage: Storage
  public let registry: ToolRegistry
  public var chatTools: [Components.Schemas.ChatTool] { registry.chatTools }
  private let client: Client
  private let workingDirectory: ScribeFilePath
  private let abortNotifier = AbortNotifier()

  public init(
    configuration: ScribeConfig,
    systemPrompt: String,
    initialMessages: [Components.Schemas.ChatMessage] = []
  ) throws {
    guard let serverURL = URL(string: configuration.serverURL) else {
      throw ScribeError.configuration(
        key: "serverURL",
        reason: "Invalid serverURL in ScribeConfig: \(configuration.serverURL)")
    }
    self.client = OpenAICompatibleClient.make(
      serverURL: serverURL, apiKey: configuration.apiKey)
    self.workingDirectory = ScribeFilePath(configuration.workingDirectory)
    self.registry = ToolRegistry(tools: configuration.tools)
    self.storage = Storage(
      systemPrompt: systemPrompt,
      model: configuration.agentModel,
      messages: initialMessages
    )
  }

  package init(
    client: Client,
    model: String,
    systemPrompt: String,
    tools: [any ScribeTool] = [],
    initialMessages: [Components.Schemas.ChatMessage] = [],
    workingDirectory: ScribeFilePath
  ) {
    self.client = client
    self.workingDirectory = workingDirectory
    self.registry = ToolRegistry(tools: tools)
    self.storage = Storage(
      systemPrompt: systemPrompt,
      model: model,
      messages: initialMessages
    )
  }

  var state: AgentStateSnapshot {
    get async { await storage.snapshot() }
  }

  public var messages: [Components.Schemas.ChatMessage] {
    get async { await storage.messages }
  }

  public func messages(since start: Int) async -> [Components.Schemas.ChatMessage] {
    await storage.messages(since: start)
  }

  public func messages(in range: Range<Int>) async -> [Components.Schemas.ChatMessage] {
    await storage.messages(in: range)
  }

  public var isStreaming: Bool {
    get async { await storage.isStreaming }
  }

  public func prompt(
    _ input: String,
    options: AgentRunOptions = AgentRunOptions(),
    log: Logger
  ) async -> TurnStream {
    let userMessage = Components.Schemas.ChatMessage(
      role: .user, content: input)
    return await prompt([userMessage], options: options, log: log)
  }

  public func prompt(
    _ promptMessages: [Components.Schemas.ChatMessage],
    options: AgentRunOptions = AgentRunOptions(),
    log: Logger
  ) async -> TurnStream {
    let (stream, continuation) = AsyncStream<TranscriptEvent>.makeStream()

    let snapshot = await storage.snapshot()
    await storage.setStreaming(true)
    abortNotifier.clear()

    let task = Task {
      [
        storage, registry, client, promptMessages, options, log,
        abortNotifier
      ] in
      defer {
        continuation.finish()
        Task { await storage.setStreaming(false) }
      }

      let ctx = AgentContext(
        systemPrompt: snapshot.systemPrompt,
        messages: snapshot.messages
      )

      let config = AgentLoopConfig(
        model: snapshot.model,
        client: client,
        registry: registry,
        temperature: options.temperature,
        maxToolRounds: options.maxToolRounds,
        workingDirectory: workingDirectory
      )

      do {
        let result = try await runAgentLoop(
          promptMessages: promptMessages,
          context: ctx,
          config: config,
          emit: { continuation.yield($0) },
          log: log,
          abortObserver: abortNotifier
        )
        switch result.termination {
        case .completed:
          await storage.appendMessages(result.messages)
          let finalMessages = await storage.messages
          return TurnResult(messages: finalMessages, outcome: .completed)
        case .interrupted:
          continuation.yield(.turnInterrupted)
          return TurnResult(messages: await storage.messages, outcome: .interrupted)
        case .toolRoundLimit(let rounds):
          return TurnResult(messages: await storage.messages, outcome: .toolRoundLimit(rounds: rounds))
        }
      } catch is AgentTurnInterruptedError {
        continuation.yield(.turnInterrupted)
        let current = await storage.messages
        return TurnResult(messages: current, outcome: .interrupted)
      }
    }

    return TurnStream(events: stream, result: task)
  }

  public func abort() {
    abortNotifier.request()
  }
}
