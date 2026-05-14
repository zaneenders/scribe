import Foundation
import Logging
import ScribeLLM

public struct ScribeAgent: Sendable {

  private actor Storage {
    var model: String
    var messages: [Components.Schemas.ChatMessage]
    var isStreaming = false

    init(
      model: String,
      messages: [Components.Schemas.ChatMessage]
    ) {
      self.model = model
      self.messages = messages
    }

    func snapshot() -> AgentStateSnapshot {
      AgentStateSnapshot(
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
  /// Schemas advertised to the LLM. Lives alongside the tool executor — even
  /// when an embedder injects a custom ``ToolExecutor``, the loop still needs
  /// to tell the model what tools exist.
  internal let chatTools: [Components.Schemas.ChatTool]
  private let toolExecutor: any ToolExecutor
  private let client: Client
  private let workingDirectory: ScribeFilePath
  private let abortNotifier = AbortNotifier()

  // MARK: - Designated initializer (transport-injected)

  /// Construct an agent against a caller-supplied ``ScribeLLM/Client``.
  ///
  /// Embedded callers (server, sub-agent, anything that wants its own
  /// transport / auth middleware / retry policy / metric tagging) use this
  /// initializer to inject a pre-built `Client` and an optional custom
  /// ``ToolExecutor`` — no `ScribeConfig`, no `Foundation.URL` parsing.
  ///
  /// If `systemPrompt` is non-empty and `initialMessages` does not begin
  /// with a `.system` message, one is inserted at the head so the model
  /// always sees the instructions even when callers prefer to pass just
  /// user/assistant history.
  ///
  /// - Parameters:
  ///   - client: HTTP client speaking the OpenAI-compatible chat
  ///     completions surface (see ``ScribeLLM/OpenAICompatibleClient``).
  ///   - model: Model id the loop sends as the `model` field.
  ///   - systemPrompt: Optional system prompt; injected into
  ///     `initialMessages` when missing.
  ///   - tools: Tool definitions whose schemas are advertised to the model.
  ///     The schema list is derived from `tools` regardless of whether a
  ///     custom executor is supplied — so callers can declare a richer
  ///     surface (e.g. tools that the executor forwards over the wire) by
  ///     handing the agent matching `ScribeTool` descriptors.
  ///     When `toolExecutor` is `nil`, these tools are also what the agent
  ///     runs in-process via a default ``ToolRegistry``.
  ///   - toolExecutor: Custom execution backend (HITL gate, sandbox
  ///     forwarder, etc.). When `nil`, a ``ToolRegistry`` built from
  ///     `tools` is used as the executor; when non-`nil`, no registry is
  ///     constructed.
  ///   - initialMessages: Pre-loaded conversation history (e.g. resumed
  ///     session). May omit a leading system message — see `systemPrompt`.
  ///   - workingDirectory: Absolute working directory used for tool path
  ///     resolution.
  public init(
    client: Client,
    model: String,
    systemPrompt: String = "",
    tools: [any ScribeTool] = [],
    toolExecutor: (any ToolExecutor)? = nil,
    initialMessages: [Components.Schemas.ChatMessage] = [],
    workingDirectory: ScribeFilePath
  ) {
    self.client = client
    self.workingDirectory = workingDirectory
    // Schemas the model is told about — always derived directly from
    // `tools`, even when a custom executor is supplied. The registry is
    // only built when we actually need it as the default executor.
    self.chatTools = tools.map { type(of: $0).toChatTool() }
    self.toolExecutor = toolExecutor ?? ToolRegistry(tools: tools)
    self.storage = Storage(
      model: model,
      messages: Self.applySystemPrompt(
        systemPrompt: systemPrompt,
        initialMessages: initialMessages)
    )
  }

  // MARK: - ScribeMessage initializer (transport-agnostic)

  /// Same shape as the wire-typed initializer above, but takes the
  /// transport-agnostic ``ScribeMessage`` for `initialMessages`. Prefer
  /// this overload from embedders that want to keep
  /// `Components.Schemas.ChatMessage` out of their type surface.
  public init(
    client: Client,
    model: String,
    systemPrompt: String = "",
    tools: [any ScribeTool] = [],
    toolExecutor: (any ToolExecutor)? = nil,
    initialMessages: [ScribeMessage],
    workingDirectory: ScribeFilePath
  ) {
    self.init(
      client: client,
      model: model,
      systemPrompt: systemPrompt,
      tools: tools,
      toolExecutor: toolExecutor,
      initialMessages: initialMessages.toChatMessages(),
      workingDirectory: workingDirectory
    )
  }

  // MARK: - ScribeConfig convenience initializer

  /// Build an agent from a ``ScribeConfig``. Internally constructs an
  /// OpenAI-compatible client from `configuration.serverURL`. Prefer the
  /// `init(client:...)` overloads for embedded use.
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
    let client = OpenAICompatibleClient.make(
      serverURL: serverURL, apiKey: configuration.apiKey)
    self.init(
      client: client,
      model: configuration.agentModel,
      systemPrompt: systemPrompt,
      tools: configuration.tools,
      toolExecutor: nil,
      initialMessages: initialMessages,
      workingDirectory: ScribeFilePath(configuration.workingDirectory)
    )
  }

  // MARK: - State accessors

  var state: AgentStateSnapshot {
    get async { await storage.snapshot() }
  }

  /// The full conversation history as ``ScribeMessage`` values — the
  /// public, transport-agnostic message type. Equivalent to ``rawMessages``
  /// but suitable for embedders that want to avoid the generated
  /// OpenAI-compatible type.
  public var messages: [ScribeMessage] {
    get async { await storage.messages.toScribeMessages() }
  }

  /// Wire-typed conversation history. Internal-leaning accessor preserved
  /// for the in-tree CLI; new embedders should prefer ``messages``.
  public var rawMessages: [Components.Schemas.ChatMessage] {
    get async { await storage.messages }
  }

  public func messages(since start: Int) async -> [ScribeMessage] {
    await storage.messages(since: start).toScribeMessages()
  }

  public func messages(in range: Range<Int>) async -> [ScribeMessage] {
    await storage.messages(in: range).toScribeMessages()
  }

  public var isStreaming: Bool {
    get async { await storage.isStreaming }
  }

  // MARK: - prompt

  public func prompt(
    _ input: String,
    options: AgentRunOptions = AgentRunOptions(),
    log: Logger
  ) async -> TurnStream {
    let userMessage = Components.Schemas.ChatMessage(
      role: .user, content: input)
    return await prompt([userMessage], options: options, log: log)
  }

  /// Send a batch of ``ScribeMessage`` values as the next turn. Convenience
  /// overload for embedders that don't want to construct OpenAI-shaped
  /// values; the messages are bridged to the wire shape internally.
  public func prompt(
    _ promptMessages: [ScribeMessage],
    options: AgentRunOptions = AgentRunOptions(),
    log: Logger
  ) async -> TurnStream {
    await prompt(promptMessages.toChatMessages(), options: options, log: log)
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
        storage, toolExecutor, chatTools, client, promptMessages, options, log,
        abortNotifier
      ] in
      defer {
        continuation.finish()
        Task { await storage.setStreaming(false) }
      }

      let ctx = AgentContext(messages: snapshot.messages)

      let config = AgentLoopConfig(
        model: snapshot.model,
        client: client,
        toolExecutor: toolExecutor,
        chatTools: chatTools,
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
          return TurnResult(
            messages: finalMessages.toScribeMessages(),
            rawMessages: finalMessages,
            outcome: .completed)
        case .interrupted:
          continuation.yield(.turnInterrupted)
          let current = await storage.messages
          return TurnResult(
            messages: current.toScribeMessages(),
            rawMessages: current,
            outcome: .interrupted)
        case .toolRoundLimit(let rounds):
          let current = await storage.messages
          return TurnResult(
            messages: current.toScribeMessages(),
            rawMessages: current,
            outcome: .toolRoundLimit(rounds: rounds))
        }
      } catch is AgentTurnInterruptedError {
        continuation.yield(.turnInterrupted)
        let current = await storage.messages
        return TurnResult(
          messages: current.toScribeMessages(),
          rawMessages: current,
          outcome: .interrupted)
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
    initialMessages: [Components.Schemas.ChatMessage]
  ) -> [Components.Schemas.ChatMessage] {
    guard !systemPrompt.isEmpty else { return initialMessages }
    if initialMessages.first?.role == .system { return initialMessages }
    var result = initialMessages
    result.insert(.init(role: .system, content: systemPrompt), at: 0)
    return result
  }
}
