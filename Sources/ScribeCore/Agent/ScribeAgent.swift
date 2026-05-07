import Foundation
import Logging
import ScribeLLM

// MARK: - ScribeAgent

/// An agent that orchestrates LLM calls with tool execution.
///
/// Instantiate with configuration, a system prompt, and an array of tools,
/// then call `streamTurn`, `runInteractive`, or `runIPC`.
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
/// // Single turn (streaming)
/// let ts = agent.streamTurn(messages: messages, log: log)
/// for await event in ts.events { /* render */ }
/// let result = try await ts.result.value
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
  private let loop: AgentLoop

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
    let harness = AgentHarness(
      client: client,
      model: configuration.agentModel,
      tools: chatTools
    )
    self.loop = AgentLoop(
      harness: harness,
      registry: toolRegistry
    )
  }

  // MARK: - streamTurn

  /// The single execution primitive. Takes an owned copy of messages, returns
  /// a live stream of ``TranscriptEvent`` values plus a `Task` that resolves
  /// with the final messages and ``ModelTurnOutcome`` when the turn completes.
  ///
  /// ```swift
  /// let ts = agent.streamTurn(messages: history, log: log)
  /// for await event in ts.events { render(event) }
  /// let result = try await ts.result.value
  /// history = result.messages
  /// ```
  public func streamTurn(
    messages: [Components.Schemas.ChatMessage],
    log: Logger,
    temperature: Double = 0,
    maxToolRounds: Int = .max,
    shouldAbortTurn: @escaping @Sendable () -> Bool = { false }
  ) -> TurnStream {
    loop.runModelStreamingTurn(
      messages: messages,
      logger: log,
      temperature: temperature,
      maxToolRounds: maxToolRounds,
      shouldAbortTurn: shouldAbortTurn
    )
  }

  // MARK: - runInteractive

  public func runInteractive(
    onEvent: @escaping @Sendable (TranscriptEvent) -> Void,
    readUserLine: @escaping @Sendable () async -> String?,
    temperature: Double = 0,
    initialConversation: [Components.Schemas.ChatMessage]? = nil,
    onConversationPersist: (@Sendable ([Components.Schemas.ChatMessage]) -> Void)? = nil,
    prepareModelTurnStart: @escaping @Sendable () -> Void = {},
    shouldAbortTurn: @escaping @Sendable () -> Bool = { false },
    log: Logger
  ) async throws {
    var history: [Components.Schemas.ChatMessage]
    if let initialConversation, !initialConversation.isEmpty {
      history = initialConversation
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
      history = [
        .init(
          role: .system,
          content: systemPrompt,
          name: nil,
          toolCalls: nil,
          toolCallId: nil
        )
      ]
    }

    let persistConversation = onConversationPersist
    persistConversation?(history)
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

      prepareModelTurnStart()
      onEvent(.modelTurnRunning(true))
      defer {
        onEvent(.modelTurnRunning(false))
      }
      let turnStart = Date()
      do {
        let ts = streamTurn(
          messages: history,
          log: log,
          temperature: temperature,
          maxToolRounds: .max,
          shouldAbortTurn: shouldAbortTurn
        )
        for await event in ts.events {
          if case .usage(let usage, _) = event {
            tracker.accumulate(usage: usage)
          }
          onEvent(event)
        }
        let result = try await ts.result.value
        history = result.messages
        let elapsedMs = Int(Date().timeIntervalSince(turnStart) * 1000)
        switch result.outcome {
        case .completed:
          log.info(
            """
            event=agent.turn.end \
            turn=\(turnIndex) \
            status=completed \
            elapsed_ms=\(elapsedMs)
            """)
          tracker.logStatus(logger: log)
        case .interrupted:
          log.notice(
            """
            event=agent.turn.end \
            turn=\(turnIndex) \
            status=interrupted \
            elapsed_ms=\(elapsedMs)
            """)
          onEvent(.turnInterrupted)
        case .toolRoundLimit(let max):
          log.notice(
            """
            event=agent.turn.end \
            turn=\(turnIndex) \
            status=tool-round-limit \
            elapsed_ms=\(elapsedMs) \
            limit=\(max)
            """)
          onEvent(.turnInterrupted)
        }
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
          history.removeLast()
        }
      }
      persistConversation?(history)
    }
    persistConversation?(history)
    log.debug(
      """
      event=chat.coordinator.end \
      transcript_messages=\(history.count) \
      turns=\(turnIndex)
      """)
  }

  // MARK: - runIPC

  public func runIPC(
    request: ScribeAgentRequest,
    temperature: Double = 0,
    onEvent: @escaping @Sendable (TranscriptEvent) -> Void,
    log: Logger
  ) async -> ScribeAgentResponse {
    var history: [Components.Schemas.ChatMessage] = [
      .init(
        role: .system,
        content: systemPrompt,
        name: nil,
        toolCalls: nil,
        toolCallId: nil
      ),
      .init(
        role: .user,
        content: request.message,
        name: nil,
        toolCalls: nil,
        toolCallId: nil
      ),
    ]
    log.notice(
      """
      event=ipc.session.start \
      message_chars=\(request.message.count) \
      model=\(configuration.agentModel)
      """)
    do {
      let ts = streamTurn(
        messages: history,
        log: log,
        temperature: temperature
      )
      Task { for await event in ts.events { onEvent(event) } }
      let result = try await ts.result.value
      history = result.messages
      let text = ChatHistory.lastAssistantText(from: history) ?? ""
      switch result.outcome {
      case .completed:
        log.notice(
          """
          event=ipc.session.end \
          status=ok \
          assistant_chars=\(text.count)
          """)
        return .success(assistant: text)
      case .interrupted:
        log.notice(
          """
          event=ipc.session.end \
          status=interrupted \
          assistant_chars=\(text.count)
          """)
        return .failure("Turn was interrupted.")
      case .toolRoundLimit(let max):
        log.notice(
          """
          event=ipc.session.end \
          status=tool-round-limit \
          max=\(max) \
          assistant_chars=\(text.count)
          """)
        return .failure("Hit maximum tool rounds (\(max)).")
      }
    } catch let e as ScribeError {
      log.error(
        """
        event=ipc.session.end \
        status=error \
        err="\(e.errorDescription ?? String(describing: e))"
        """)
      return .failure(e.errorDescription ?? String(describing: e))
    } catch {
      log.error(
        """
        event=ipc.session.end \
        status=error \
        err="\(String(describing: error))"
        """)
      return .failure(String(describing: error))
    }
  }
}
