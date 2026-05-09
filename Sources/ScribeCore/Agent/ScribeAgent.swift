import Foundation
import Logging
import ScribeLLM
import Synchronization

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
struct AgentStateSnapshot: Sendable {
  let systemPrompt: String
  let model: String
  let messages: [Components.Schemas.ChatMessage]
  let isStreaming: Bool

  init(
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

    /// Return only messages at or after `start` index (avoids copying the full
    /// transcript when only the tail is needed, e.g. incremental persist).
    func messages(since start: Int) -> [Components.Schemas.ChatMessage] {
      guard start < messages.count else { return [] }
      let clamped = max(start, 0)
      return Array(messages[clamped...])
    }

    /// Return messages in `range`, clamped to valid indices.
    func messages(in range: Range<Int>) -> [Components.Schemas.ChatMessage] {
      let lower = max(0, range.lowerBound)
      let upper = min(messages.count, range.upperBound)
      guard lower < upper else { return [] }
      return Array(messages[lower..<upper])
    }

    func setStreaming(_ value: Bool) { isStreaming = value }
  }

  // ── Stored properties ────────────────────────────────

  private let storage: Storage

  /// The tool registry derived from the tools passed at construction.
  public let registry: ToolRegistry

  /// The chat tool schemas sent to the LLM, provided by the registry.
  public var chatTools: [Components.Schemas.ChatTool] { registry.chatTools }

  /// The OpenAI-compatible HTTP client.
  private let client: Client

  /// Absolute working directory for tool path resolution.
  private let workingDirectory: ScribeFilePath

  /// Synchronous abort flag checked by the run loop without `await`.
  private final class AbortFlag: Sendable {
    let value = Atomic<Bool>(false)
  }
  private let abortFlag = AbortFlag()

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
    self.workingDirectory = ScribeFilePath(configuration.workingDirectory)
    self.registry = ToolRegistry(tools: configuration.tools)
    self.storage = Storage(
      systemPrompt: systemPrompt,
      model: configuration.agentModel,
      messages: initialMessages
    )
  }

  /// Creates an agent with a pre-built client (for testing or custom transports).
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

  // MARK: - Public state

  /// A snapshot of the current agent state.
  var state: AgentStateSnapshot {
    get async { await storage.snapshot() }
  }

  /// The current transcript messages.
  public var messages: [Components.Schemas.ChatMessage] {
    get async { await storage.messages }
  }

  /// Return only messages at or after `start` index, avoiding a full
  /// transcript copy when only the tail (e.g. incremental persist) is needed.
  public func messages(since start: Int) async -> [Components.Schemas.ChatMessage] {
    await storage.messages(since: start)
  }

  /// Return messages in `range`, clamped to valid indices.
  public func messages(in range: Range<Int>) async -> [Components.Schemas.ChatMessage] {
    await storage.messages(in: range)
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
    abortFlag.value.store(false, ordering: .sequentiallyConsistent)

    let task = Task {
      [
        storage, registry, client, promptMessages, options, log,
        abortFlag
      ] in
      defer {
        continuation.finish()
        Task { await storage.setStreaming(false) }
      }

      // Combine agent-level abort with caller-level abort
      let shouldAbort: @Sendable () -> Bool = {
        abortFlag.value.load(ordering: .sequentiallyConsistent)
          || options.shouldAbortTurn?() == true
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

  // MARK: - Abort

  /// Abort the current run, if one is active.
  public func abort() {
    abortFlag.value.store(true, ordering: .sequentiallyConsistent)
  }
}
