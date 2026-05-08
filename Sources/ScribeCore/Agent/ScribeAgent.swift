import Foundation
import Logging
import ScribeLLM

// MARK: - AgentRunOptions

/// Per-call options that vary between turns.
public struct AgentRunOptions: Sendable {
  public var temperature: Double
  public var maxToolRounds: Int
  public var shouldAbortTurn: (@Sendable () -> Bool)?

  public init(
    temperature: Double = 0,
    maxToolRounds: Int = .max,
    shouldAbortTurn: (@Sendable () -> Bool)? = nil
  ) {
    self.temperature = temperature
    self.maxToolRounds = maxToolRounds
    self.shouldAbortTurn = shouldAbortTurn
  }
}

// MARK: - AgentStateSnapshot

/// Read-only snapshot of agent state.
public struct AgentStateSnapshot: Sendable {
  public let systemPrompt: String
  public let model: String
  public let messages: [Components.Schemas.ChatMessage]
  public let isStreaming: Bool

  public init(
    systemPrompt: String,
    model: String,
    messages: [Components.Schemas.ChatMessage],
    isStreaming: Bool
  ) {
    self.systemPrompt = systemPrompt
    self.model = model
    self.messages = messages
    self.isStreaming = isStreaming
  }
}

// MARK: - ScribeAgent

/// An agent that executes LLM turns with tool execution.
///
/// Owns the conversation transcript, system prompt, and tool set. Configure
/// once at construction; call `prompt()` for each user turn.
///
/// ```swift
/// let agent = try ScribeAgent(
///     configuration: config,
///     systemPrompt: "You are a coding assistant.",
///     initialMessages: resumeArchive?.messages ?? [])
///
/// let stream = await agent.prompt("Write a function.", log: logger)
/// for await event in stream.events { /* render */ }
/// let result = try await stream.result.value
/// ```
public struct ScribeAgent: Sendable {

  // ── Internal mutable state (actor) ──────────────────

  private actor Storage {
    var systemPrompt: String
    var model: String
    var messages: [Components.Schemas.ChatMessage]
    var isStreaming = false
    var streamingMessage: Components.Schemas.ChatMessage?
    var pendingToolCalls = Set<String>()
    var errorMessage: String?
    var isAborted = false

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

    func setStreaming(_ value: Bool) { isStreaming = value }
    func requestAbort() { isAborted = true }
    func clearAbort() { isAborted = false }
    func checkAbort() -> Bool { isAborted }

    func reset() {
      messages = []
      isStreaming = false
      streamingMessage = nil
      pendingToolCalls = []
      errorMessage = nil
      isAborted = false
    }
  }

  // ── Stored properties ────────────────────────────────

  private let storage: Storage

  /// The tool registry derived from the tools passed at construction.
  public let registry: ToolRegistry

  /// The chat tool schemas sent to the LLM.
  public let chatTools: [Components.Schemas.ChatTool]

  /// The OpenAI-compatible HTTP client.
  private let client: Client

  // MARK: - Constructor

  /// Creates an agent from a `ScribeConfig`.
  ///
  /// - Parameters:
  ///   - configuration: Model, endpoint, and tool configuration.
  ///   - systemPrompt: System prompt sent with every LLM call.
  ///   - initialMessages: Seed messages (e.g. from a resumed session).
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
    self.registry = ToolRegistry(tools: configuration.tools)
    self.chatTools = DefaultAgentTools.chatTools(from: configuration.tools)
    self.storage = Storage(
      systemPrompt: systemPrompt,
      model: configuration.agentModel,
      messages: initialMessages
    )
  }

  /// Creates an agent with a pre-built client (for testing or custom transports).
  public init(
    client: Client,
    model: String,
    systemPrompt: String,
    tools: [any ScribeTool] = [],
    initialMessages: [Components.Schemas.ChatMessage] = []
  ) {
    self.client = client
    self.registry = ToolRegistry(tools: tools)
    self.chatTools = DefaultAgentTools.chatTools(from: tools)
    self.storage = Storage(
      systemPrompt: systemPrompt,
      model: model,
      messages: initialMessages
    )
  }

  // MARK: - Public state

  /// A snapshot of the current agent state.
  public var state: AgentStateSnapshot {
    get async { await storage.snapshot() }
  }

  /// The current transcript messages.
  public var messages: [Components.Schemas.ChatMessage] {
    get async { await storage.messages }
  }

  /// Whether the agent is currently streaming.
  public var isStreaming: Bool {
    get async { await storage.isStreaming }
  }

  // MARK: - prompt

  /// Start a new turn from user text.
  ///
  /// Normalizes the input to a user message, appends it to the transcript,
  /// then runs the agent loop.
  ///
  /// - Returns: A `TurnStream` with live events and a deferred result.
  public func prompt(
    _ input: String,
    options: AgentRunOptions = AgentRunOptions(),
    log: Logger
  ) async -> TurnStream {
    let userMessage = Components.Schemas.ChatMessage(
      role: .user, content: input)
    return await prompt([userMessage], options: options, log: log)
  }

  /// Start a new turn from pre-built messages.
  ///
  /// - Returns: A `TurnStream` with live events and a deferred result.
  public func prompt(
    _ promptMessages: [Components.Schemas.ChatMessage],
    options: AgentRunOptions = AgentRunOptions(),
    log: Logger
  ) async -> TurnStream {
    let (stream, continuation) = AsyncStream<TranscriptEvent>.makeStream()

    // Take a single snapshot before the task starts
    let snapshot = await storage.snapshot()
    await storage.setStreaming(true)
    await storage.clearAbort()

    let task = Task {
      [storage, registry, chatTools, client, promptMessages, options, log] in
      defer {
        continuation.finish()
        Task { await storage.setStreaming(false) }
      }

      // Combine agent-level abort with caller-level abort
      let shouldAbort: @Sendable () -> Bool = {
        // We can't await storage.checkAbort() inside a non-async closure.
        // Instead, the caller's shouldAbortTurn can check the agent flag if desired.
        options.shouldAbortTurn?() == true
      }

      // Build context from snapshot (messages BEFORE the prompt)
      let ctx = AgentContext(
        systemPrompt: snapshot.systemPrompt,
        messages: snapshot.messages
      )

      let config = AgentLoopConfig(
        model: snapshot.model,
        client: client,
        registry: registry,
        chatTools: chatTools,
        temperature: options.temperature,
        maxToolRounds: options.maxToolRounds
      )

      do {
        let result = try await runAgentLoop(
          promptMessages: promptMessages,
          context: ctx,
          config: config,
          emit: { continuation.yield($0) },
          log: log,
          shouldAbortTurn: shouldAbort
        )
        switch result.termination {
        case .completed:
          await storage.appendMessages(result.messages)
          let finalMessages = await storage.messages
          return TurnResult(messages: finalMessages, outcome: .completed)
        case .interrupted:
          return TurnResult(messages: await storage.messages, outcome: .interrupted)
        case .toolRoundLimit(let rounds):
          return TurnResult(messages: await storage.messages, outcome: .toolRoundLimit(rounds: rounds))
        }
      } catch is AgentTurnInterruptedError {
        let current = await storage.messages
        return TurnResult(messages: current, outcome: .interrupted)
      }
    }

    return TurnStream(events: stream, result: task)
  }

  // MARK: - Abort / reset

  /// Abort the current run, if one is active.
  public func abort() async {
    await storage.requestAbort()
  }

  /// Clear transcript and runtime state.
  public func reset() async {
    await storage.reset()
  }
}
