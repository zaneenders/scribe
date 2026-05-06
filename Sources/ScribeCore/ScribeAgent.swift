import Foundation
import Logging
import ScribeLLM

// MARK: - ScribeAgent

/// An agent that orchestrates LLM calls with tool execution.
///
/// Instantiate with configuration, a system prompt, and an array of tools,
/// then call `runTurn` or `runInteractive`.
///
/// ```swift
/// let config = AgentConfig(
///   agentModel: "llama3.2",
///   serverURL: "http://localhost:11434"
/// )
/// let agent = ScribeAgent(
///   configuration: config,
///   systemPrompt: "You are a helpful coding assistant.",
///   tools: [ShellTool(), ReadFileTool(), WriteFileTool(), EditFileTool()]
/// )
///
/// // Single turn
/// var messages: [ChatMessage] = [.init(role: .system, content: "...")]
/// let outcome = try await agent.runTurn(messages: &messages, ...)
///
/// // Full interactive session
/// try await agent.runInteractive(onEvent: ..., readUserLine: ..., log: ...)
/// ```
public struct ScribeAgent: Sendable {
  public let configuration: AgentConfig
  public let client: Client
  public let systemPrompt: String
  public let toolRegistry: ToolRegistry

  private let chatTools: [Components.Schemas.ChatTool]

  /// Primary initializer: provide an `AgentConfig` that includes the server URL
  /// and optional bearer token; the HTTP client is created internally.
  public init(
    configuration: AgentConfig,
    systemPrompt: String,
    tools: [any ScribeTool]
  ) {
    guard let serverURL = URL(string: configuration.serverURL) else {
      fatalError("Invalid serverURL in AgentConfig: \(configuration.serverURL)")
    }
    self.init(
      configuration: configuration,
      client: OpenAICompatibleClient.make(
        serverURL: serverURL, bearerToken: configuration.bearerToken),
      systemPrompt: systemPrompt,
      tools: tools
    )
  }

  /// Escape hatch: provide a pre-configured `Client` directly (e.g. for testing
  /// with a custom transport).
  public init(
    configuration: AgentConfig,
    client: Client,
    systemPrompt: String,
    tools: [any ScribeTool]
  ) {
    self.configuration = configuration
    self.client = client
    self.systemPrompt = systemPrompt
    self.toolRegistry = ToolRegistry(tools: tools)
    self.chatTools = DefaultAgentTools.chatTools(from: tools)
  }

  // MARK: - runTurn

  /// Execute a single model turn (LLM call + optional tool-call rounds) against
  /// the supplied conversation history. The caller owns `messages` and can
  /// inspect / persist / replay it between turns.
  public func runTurn(
    messages: inout MessageRope,
    log: Logger,
    onEvent: @escaping @Sendable (TranscriptEvent) -> Void,
    shouldAbortTurn: @escaping @Sendable () -> Bool = { false }
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
      messages: &messages,
      logger: log,
      shouldAbortTurn: shouldAbortTurn
    )
  }

  // MARK: - runInteractive

  public func runInteractive(
    onEvent: @escaping @Sendable (TranscriptEvent) -> Void,
    readUserLine: @escaping @Sendable () async -> String?,
    initialConversation: [Components.Schemas.ChatMessage]? = nil,
    onConversationPersist: (@Sendable ([Components.Schemas.ChatMessage]) -> Void)? = nil,
    onRopeUpdate: (@Sendable (MessageRope) -> Void)? = nil,
    prepareModelTurnStart: @escaping @Sendable () -> Void = {},
    shouldAbortTurn: @escaping @Sendable () -> Bool = { false },
    log: Logger
  ) async throws {
    var history: MessageRope
    if let initialConversation, !initialConversation.isEmpty {
      history = MessageRope(initialConversation)
      if history.first?.role != .system {
        log.error(
          """
          event=chat.coordinator.fail \
          reason=resumed-history-no-system-prefix \
          first_role=\(String(describing: history.first?.role))
          """)
        throw ScribeError.sessionCorrupted(
          reason: "Resumed conversation must begin with a system message.")
      }
    } else {
      history = MessageRope()
      history.append(
        .init(
          role: .system,
          content: systemPrompt,
          name: nil,
          toolCalls: nil,
          toolCallId: nil
        )
      )
    }

    let persistConversation = onConversationPersist
    persistConversation?(extractArray(from: history))
    onRopeUpdate?(history)
    log.debug(
      """
      event=chat.coordinator.start \
      messages=\(history.count) \
      resumed=\(initialConversation != nil)
      """)

    let tracker = TokenTracker(
      contextWindow: configuration.contextWindow,
      threshold: configuration.contextWindowThreshold
    )

    let wrappedOnEvent: @Sendable (TranscriptEvent) -> Void = { event in
      if case .usage(let usage, _) = event {
        tracker.accumulate(usage: usage)
      }
      onEvent(event)
    }

    var turnIndex = 0
    while true {
      guard let line = await readUserLine() else {
        log.info("event=chat.user.eof reason=stdin-closed")
        break
      }
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed == "exit" {
        log.notice("event=chat.user.exit-command")
        break
      }
      if trimmed.isEmpty {
        log.trace("event=chat.user.empty-skip")
        continue
      }
      turnIndex += 1
      log.debug(
        """
        event=agent.turn.dispatch \
        turn=\(turnIndex) \
        chars=\(trimmed.count)
        """)

      history.append(
        .init(
          role: .user,
          content: trimmed,
          name: nil,
          toolCalls: nil,
          toolCallId: nil
        ))
      onRopeUpdate?(history)

      prepareModelTurnStart()
      onEvent(.modelTurnRunning(true))
      defer {
        onEvent(.modelTurnRunning(false))
      }
      let turnStart = Date()
      do {
        let _ = try await runTurn(
          messages: &history,
          log: log,
          onEvent: wrappedOnEvent,
          shouldAbortTurn: shouldAbortTurn
        )
        let elapsedMs = Int(Date().timeIntervalSince(turnStart) * 1000)
        log.info(
          """
          event=agent.turn.end \
          turn=\(turnIndex) \
          status=completed \
          elapsed_ms=\(elapsedMs)
          """)
        tracker.logStatus(logger: log)
      } catch is AgentTurnInterruptedError {
        let elapsedMs = Int(Date().timeIntervalSince(turnStart) * 1000)
        log.notice(
          """
          event=agent.turn.end \
          turn=\(turnIndex) \
          status=interrupted \
          elapsed_ms=\(elapsedMs)
          """)
        onEvent(.turnInterrupted)
      } catch {
        let elapsedMs = Int(Date().timeIntervalSince(turnStart) * 1000)
        let scribeError = (error as? ScribeError) ?? .generic(String(describing: error))
        log.error(
          """
          event=agent.turn.end \
          turn=\(turnIndex) \
          status=error \
          elapsed_ms=\(elapsedMs) \
          err="\(scribeError.errorDescription ?? String(describing: scribeError))"
          """)
        onEvent(.harnessError(scribeError))
        if history.last?.role == .user {
          history.truncate(to: history.count - 1)
        }
      }
      onRopeUpdate?(history)
      persistConversation?(extractArray(from: history))
    }
    persistConversation?(extractArray(from: history))
    log.debug(
      """
      event=chat.coordinator.end \
      transcript_messages=\(history.count) \
      turns=\(turnIndex)
      """)
  }

  // MARK: - Helpers

  private func extractArray(from rope: MessageRope) -> [Components.Schemas.ChatMessage] {
    rope.window(from: 0, count: rope.count)
  }
}
