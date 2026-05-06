import Foundation
import Logging
import ScribeLLM

// MARK: - ScribeAgent

/// An agent that orchestrates LLM calls with tool execution.
///
/// The agent owns the conversation history (`MessageRope`) and the system prompt.
/// The caller drives the turn loop — the history is seeded on init, append user
/// messages, call `runTurn()`, inspect `history` at any time.
///
/// ```swift
/// let agent = try ScribeAgent(
///     configuration: config,
///     systemPrompt: "You are a helpful coding assistant.",
///     tools: [ShellTool(), ReadFileTool(), WriteFileTool(), EditFileTool()]
/// )
///
/// // Full interactive session
/// while let line = await readLine() {
///     agent.appendUserMessage(line)
///     let outcome = try await agent.runTurn(onEvent: ..., log: ...)
///     persist(agent.history.window(from: 0, count: agent.history.count))
/// }
/// ```
public struct ScribeAgent: Sendable {
  public let configuration: AgentConfig
  public let client: Client
  public let systemPrompt: String
  public let toolRegistry: ToolRegistry
  public var history: MessageRope

  private let chatTools: [Components.Schemas.ChatTool]

  // MARK: - Init

  /// Primary initializer: provide an `AgentConfig` that includes the server URL
  /// and optional bearer token; the HTTP client is created internally.
  ///
  /// If `resumeFrom` is supplied its first message must be a system message;
  /// otherwise the history is seeded with `systemPrompt`.
  public init(
    configuration: AgentConfig,
    systemPrompt: String,
    tools: [any ScribeTool],
    resumeFrom messages: [Components.Schemas.ChatMessage]? = nil
  ) throws {
    guard let serverURL = URL(string: configuration.serverURL) else {
      fatalError("Invalid serverURL in AgentConfig: \(configuration.serverURL)")
    }
    try self.init(
      configuration: configuration,
      client: OpenAICompatibleClient.make(
        serverURL: serverURL, bearerToken: configuration.bearerToken),
      systemPrompt: systemPrompt,
      tools: tools,
      resumeFrom: messages
    )
  }

  /// Escape hatch: provide a pre-configured `Client` directly (e.g. for testing
  /// with a custom transport).
  internal init(
    configuration: AgentConfig,
    client: Client,
    systemPrompt: String,
    tools: [any ScribeTool],
    resumeFrom messages: [Components.Schemas.ChatMessage]? = nil
  ) throws {
    self.configuration = configuration
    self.client = client
    self.systemPrompt = systemPrompt
    self.toolRegistry = ToolRegistry(tools: tools)
    self.chatTools = DefaultAgentTools.chatTools(from: tools)

    if let messages, !messages.isEmpty {
      guard messages.first?.role == .system else {
        throw ScribeError.sessionCorrupted(
          reason: "Resumed conversation must begin with a system message.")
      }
      self.history = MessageRope(messages)
    } else {
      self.history = MessageRope()
      self.history.append(
        .init(
          role: .system,
          content: systemPrompt,
          name: nil,
          toolCalls: nil,
          toolCallId: nil
        )
      )
    }
  }

  /// Append a user message to the conversation history.
  public mutating func appendUserMessage(_ text: String) {
    history.append(
      .init(
        role: .user,
        content: text,
        name: nil,
        toolCalls: nil,
        toolCallId: nil
      )
    )
  }

  // MARK: - runTurn

  /// Execute a single model turn (LLM call + optional tool-call rounds) against
  /// `self.history`.  The caller owns the loop and can inspect / persist / replay
  /// `history` between turns.
  public mutating func runTurn(
    onEvent: @escaping @Sendable (TranscriptEvent) -> Void,
    shouldAbortTurn: @escaping @Sendable () -> Bool = { false },
    log: Logger
  ) async throws -> ModelTurnOutcome {
    let harness = AgentHarness(
      onEvent: onEvent,
      client: client,
      model: configuration.agentModel,
      tools: chatTools,
      maxContextMessages: configuration.maxContextMessages
    )
    let loop = AgentLoop(
      harness: harness,
      registry: toolRegistry,
      onEvent: onEvent
    )
    return try await loop.runModelTurn(
      messages: &history,
      logger: log,
      shouldAbortTurn: shouldAbortTurn
    )
  }

  // MARK: - Helpers

  /// Extract the full conversation history as a flat array.
  public func extractMessages() -> [Components.Schemas.ChatMessage] {
    history.window(from: 0, count: history.count)
  }
}
