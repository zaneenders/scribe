import SystemPackage
import Foundation
import Logging
import ScribeLLM


/// A pure-verb model client.
///
/// `ScribeAgent` holds the configuration needed to drive a single LLM
/// turn — model id, transport, tool schemas, execution backend — and
/// nothing else. The caller owns the conversation history (typically in
/// a ``SessionDocument``) and passes a snapshot in per call. The
/// returned ``TurnStream`` carries live events plus a ``TurnResult``
/// whose ``TurnResult/newMessages`` is just the diff for the caller to
/// fold back into its own state.
///
/// The agent has no concept of "current session" — it can be invoked
/// against different histories in parallel without interference.
public struct ScribeAgent: Sendable {

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


  /// Construct an agent against a caller-supplied transport.
  ///
  /// - Parameters:
  ///   - client: HTTP client speaking the OpenAI-compatible chat
  ///     completions surface (see ``ScribeLLM/OpenAICompatibleClient``).
  ///   - model: Model id sent on the wire.
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


  /// Build an agent from a ``ScribeConfig``. Internally constructs an
  /// OpenAI-compatible client from `configuration.serverURL`.
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


  /// Run a turn with a single user input against `history`.
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

  /// Run a turn with one or more prompt messages against `history`.
  ///
  /// The agent reads `history` once at the start of the turn and never
  /// mutates the caller's state. ``TurnResult/newMessages`` contains
  /// only the messages produced during this turn (assistant deltas, tool
  /// invocations, tool results) — the caller is responsible for
  /// appending them to its own conversation store.
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
        // `runAgentLoop` already includes the prompt messages at the
        // head of `result.messages`, so the diff for the caller is
        // exactly that array.
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
        // No loop messages got committed; the prompt was never persisted.
        return TurnResult(newMessages: [], outcome: .interrupted)
      }
    }

    return TurnStream(events: stream, result: task)
  }

  public func abort() {
    abortNotifier.request()
  }
}
