import SystemPackage
import Foundation
import Logging
import ScribeLLM

public struct ScribeAgent: Sendable {

  /// Flag used by ``isStreaming``. The transcript and identity now live on
  /// the ``SessionDocument``; only the streaming flag remained agent-local.
  private actor StreamingFlag {
    var value = false
    func get() -> Bool { value }
    func set(_ v: Bool) { value = v }
  }

  private let document: SessionDocument
  private let streamingFlag = StreamingFlag()
  private let model: String
  private let reasoningEnabled: Bool?
  /// Schemas advertised to the LLM. Lives alongside the tool executor — even
  /// when an embedder injects a custom ``ToolExecutor``, the loop still needs
  /// to tell the model what tools exist.
  internal let chatTools: [Components.Schemas.ChatTool]
  private let toolExecutor: any ToolExecutor
  private let client: Client
  private let workingDirectory: FilePath
  private let logger: Logger
  private let abortNotifier = AbortNotifier()

  // MARK: - Designated initializer (document-backed)

  /// Construct an agent that reads from / writes to a caller-supplied
  /// ``SessionDocument``. The same document can be shared with the chat
  /// host so picker commands (`/fork`, `/tldr`) and agent appends both
  /// land on the same in-memory + on-disk state.
  ///
  /// - Parameters:
  ///   - client: HTTP client speaking the OpenAI-compatible chat
  ///     completions surface (see ``ScribeLLM/OpenAICompatibleClient``).
  ///   - model: Model id sent on the wire.
  ///   - document: Shared session state. The agent reads its snapshot at
  ///     the start of every turn and applies an ``EditOp/append(_:)`` at
  ///     the end of every turn.
  ///   - tools: Tool schemas advertised to the model (also used by the
  ///     default ``ToolRegistry`` when `toolExecutor` is `nil`).
  ///   - toolExecutor: Custom execution backend (HITL gate, sandbox,
  ///     etc.). `nil` → an in-process ``ToolRegistry`` is built from
  ///     `tools`.
  ///   - workingDirectory: Absolute working directory for tool path
  ///     resolution.
  ///   - reasoningEnabled: Forwarded as the `reasoning.enabled` flag on
  ///     completion requests; `nil` omits the field.
  ///   - logger: Caller-owned logger for the agent loop and built-in
  ///     tools.
  public init(
    client: Client,
    model: String,
    document: SessionDocument,
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
    self.document = document
    if let customExecutor = toolExecutor {
      self.toolExecutor = customExecutor
      self.chatTools = tools.map { type(of: $0).toChatTool(logger: logger) }
    } else {
      let registry = ToolRegistry(tools: tools, logger: logger)
      self.toolExecutor = registry
      self.chatTools = registry.chatTools
    }
  }

  // MARK: - Convenience initializers (in-memory document)

  /// Construct an agent against a caller-supplied transport, building an
  /// in-memory ``SessionDocument`` seeded with `initialMessages`.
  ///
  /// Use this for embedders that don't need on-disk persistence (server,
  /// sub-agent, tests). For a CLI-style session-on-disk, construct a
  /// ``SessionDocument`` with a file-backed ``SessionPersister`` and pass
  /// it to the document-backed init.
  ///
  /// If `systemPrompt` is non-empty and `initialMessages` doesn't begin
  /// with a `.system` message, one is inserted at the head so the model
  /// always sees the instructions.
  public init(
    client: Client,
    model: String,
    systemPrompt: String = "",
    tools: [any ScribeTool] = [],
    toolExecutor: (any ToolExecutor)? = nil,
    initialMessages: [ScribeMessage] = [],
    workingDirectory: FilePath,
    reasoningEnabled: Bool?,
    logger: Logger
  ) {
    let seeded = Self.applySystemPrompt(
      systemPrompt: systemPrompt, initialMessages: initialMessages)
    let doc = SessionDocument(
      sessionId: UUID(),
      directory: FilePath("/in-memory"),
      initialMessages: seeded,
      persister: InMemorySessionPersister(),
      logger: logger
    )
    self.init(
      client: client,
      model: model,
      document: doc,
      tools: tools,
      toolExecutor: toolExecutor,
      workingDirectory: workingDirectory,
      reasoningEnabled: reasoningEnabled,
      logger: logger
    )
  }

  /// Build an agent from a ``ScribeConfig`` against a caller-supplied
  /// ``SessionDocument``. Constructs the transport from
  /// `configuration.serverURL` so embedders don't have to reach into
  /// ``ScribeLLM``.
  public init(
    configuration: ScribeConfig,
    document: SessionDocument,
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
      document: document,
      tools: configuration.tools,
      toolExecutor: nil,
      workingDirectory: FilePath(configuration.workingDirectory),
      reasoningEnabled: configuration.reasoningEnabled,
      logger: logger
    )
  }

  /// Build an agent from a ``ScribeConfig``. Internally constructs an
  /// OpenAI-compatible client from `configuration.serverURL` and an
  /// in-memory ``SessionDocument``. Prefer the
  /// `init(configuration:document:logger:)` overload when sharing state
  /// with a host.
  public init(
    configuration: ScribeConfig,
    systemPrompt: String,
    initialMessages: [ScribeMessage] = [],
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
      systemPrompt: systemPrompt,
      tools: configuration.tools,
      toolExecutor: nil,
      initialMessages: initialMessages,
      workingDirectory: FilePath(configuration.workingDirectory),
      reasoningEnabled: configuration.reasoningEnabled,
      logger: logger
    )
  }

  // MARK: - State accessors

  /// The full conversation history as ``ScribeMessage`` values — the
  /// public, transport-agnostic message type.
  public var messages: [ScribeMessage] {
    get async { await document.snapshot() }
  }

  public func messages(since start: Int) async -> [ScribeMessage] {
    let all = await document.snapshot()
    guard start < all.count else { return [] }
    let clamped = max(0, start)
    return Array(all[clamped...])
  }

  public func messages(in range: Range<Int>) async -> [ScribeMessage] {
    let all = await document.snapshot()
    let lower = max(0, range.lowerBound)
    let upper = min(all.count, range.upperBound)
    guard lower < upper else { return [] }
    return Array(all[lower..<upper])
  }

  public var isStreaming: Bool {
    get async { await streamingFlag.get() }
  }

  // MARK: - stream

  public func stream(
    _ input: String,
    options: AgentRunOptions = AgentRunOptions()
  ) async -> TurnStream {
    await stream([ScribeMessage(role: .user, content: input)], options: options)
  }

  /// Send a batch of ``ScribeMessage`` values as the next turn. Messages
  /// are bridged to the wire shape once on the way into ``runAgentLoop`` —
  /// the OpenAPI type never crosses the public API surface.
  public func stream(
    _ promptMessages: [ScribeMessage],
    options: AgentRunOptions = AgentRunOptions()
  ) async -> TurnStream {
    let wireMessages = promptMessages.toChatMessages()
    let (stream, continuation) = AsyncStream<AgentEvent>.makeStream()

    let preTurnSnapshot = await document.snapshotChatMessages()
    await streamingFlag.set(true)
    abortNotifier.clear()

    let agentLogger = logger
    let task = Task {
      [
        document, streamingFlag, toolExecutor, chatTools, client, wireMessages, options,
        agentLogger, abortNotifier, model, reasoningEnabled, workingDirectory
      ] in
      defer {
        continuation.finish()
        Task { await streamingFlag.set(false) }
      }

      let ctx = AgentContext(messages: preTurnSnapshot)

      let config = AgentLoopConfig(
        model: model,
        client: client,
        toolExecutor: toolExecutor,
        chatTools: chatTools,
        temperature: options.temperature,
        maxToolRounds: options.maxToolRounds,
        workingDirectory: workingDirectory,
        reasoningEnabled: reasoningEnabled
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
        let newScribeMessages = result.messages.toScribeMessages()
        switch result.termination {
        case .completed:
          try await document.apply(.append(newScribeMessages))
          let finalMessages = await document.snapshot()
          return TurnResult(messages: finalMessages, outcome: .completed)
        case .interrupted:
          continuation.yield(.lifecycle(.interrupted))
          try await document.apply(.append(newScribeMessages))
          let finalMessages = await document.snapshot()
          return TurnResult(messages: finalMessages, outcome: .interrupted)
        case .toolRoundLimit(let rounds):
          try await document.apply(.append(newScribeMessages))
          let finalMessages = await document.snapshot()
          return TurnResult(
            messages: finalMessages, outcome: .toolRoundLimit(rounds: rounds))
        }
      } catch is AgentTurnInterruptedError {
        continuation.yield(.lifecycle(.interrupted))
        let current = await document.snapshot()
        return TurnResult(messages: current, outcome: .interrupted)
      }
    }

    return TurnStream(events: stream, result: task)
  }

  public func abort() {
    abortNotifier.request()
  }

  // MARK: - Helpers

  /// Inject a system message at the head of `initialMessages` when one is
  /// not already present and a non-empty `systemPrompt` is supplied. Keeps
  /// older callers (which baked the system message into `initialMessages`)
  /// working unchanged.
  private static func applySystemPrompt(
    systemPrompt: String,
    initialMessages: [ScribeMessage]
  ) -> [ScribeMessage] {
    guard !systemPrompt.isEmpty else { return initialMessages }
    if initialMessages.first?.role == .system { return initialMessages }
    var result = initialMessages
    result.insert(ScribeMessage(role: .system, content: systemPrompt), at: 0)
    return result
  }
}
