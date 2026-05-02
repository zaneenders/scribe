import Foundation
import Logging
import ScribeLLM

public enum ScribeAgentCoordinator {

  /// Interactive session; `systemPrompt` is supplied by the CLI (or another host).
  ///
  /// Supply `readUserLine` to integrate with alternate-screen TUIs (for example Slate) or stdin
  /// that is not `readLine()`-friendly.
  ///
  /// `log` is the per-session logger created by the caller (typically
  /// ``AgentConfig/makeSessionLogger(sessionId:)``); the same logger is shared across all model
  /// turns in the session so every event lands in one `scribe-{uuid}.log` file.
  public static func runInteractive(
    configuration: AgentConfig,
    client: Client,
    systemPrompt: String,
    sink: any ScribeAgentOutput,
    readUserLine: @escaping @Sendable () async -> String?,
    initialConversation: [Components.Schemas.ChatMessage]? = nil,
    onConversationPersist: (@Sendable ([Components.Schemas.ChatMessage]) -> Void)? = nil,
    prepareModelTurnStart: @escaping @Sendable () -> Void = {},
    shouldAbortTurn: @escaping @Sendable () -> Bool = { false },
    log: Logger
  ) async throws {
    let cwd = FileManager.default.currentDirectoryPath
    sink.printConfigBanner(
      baseURL: configuration.openAIBaseURL,
      model: configuration.agentModel,
      cwd: cwd
    )

    var history: [Components.Schemas.ChatMessage]
    if let initialConversation, !initialConversation.isEmpty {
      history = initialConversation
      if history.first?.role != .system {
        log.error(
          """
          event=chat.coordinator.fail \
          reason=resumed-history-no-system-prefix \
          first_role=\(String(describing: history.first?.role))
          """
        )
        throw AgentAPIError(description: "Resumed conversation must begin with a system message.")
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
      """
    )

    let harness = AgentHarness(
      output: sink,
      client: client,
      model: configuration.agentModel,
      maxToolRounds: configuration.agentMaxToolRounds
    )

    var turnIndex = 0
    while true {
      sink.printUserPromptDecoration()
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
        """
      )

      history.append(
        .init(
          role: .user,
          content: trimmed,
          name: nil,
          toolCalls: nil,
          toolCallId: nil
        )
      )

      prepareModelTurnStart()
      try sink.markModelTurnRunning(true)
      defer {
        try? sink.markModelTurnRunning(false)
      }
      let turnStart = Date()
      do {
        let outcome = try await harness.runModelTurn(
          messages: &history,
          logger: log,
          shouldAbortTurn: shouldAbortTurn
        )
        let elapsedMs = Int(Date().timeIntervalSince(turnStart) * 1000)
        switch outcome {
        case .completed:
          log.info(
            """
            event=agent.turn.end \
            turn=\(turnIndex) \
            status=completed \
            elapsed_ms=\(elapsedMs)
            """
          )
        case .hitToolRoundLimit:
          log.notice(
            """
            event=agent.turn.end \
            turn=\(turnIndex) \
            status=tool-round-limit \
            limit=\(configuration.agentMaxToolRounds) \
            elapsed_ms=\(elapsedMs)
            """
          )
        }
      } catch is AgentTurnInterruptedError {
        let elapsedMs = Int(Date().timeIntervalSince(turnStart) * 1000)
        log.notice(
          """
          event=agent.turn.end \
          turn=\(turnIndex) \
          status=interrupted \
          elapsed_ms=\(elapsedMs)
          """
        )
        try sink.printTurnInterrupted()
      } catch {
        let elapsedMs = Int(Date().timeIntervalSince(turnStart) * 1000)
        log.error(
          """
          event=agent.turn.end \
          turn=\(turnIndex) \
          status=error \
          elapsed_ms=\(elapsedMs) \
          err="\(String(describing: error))"
          """
        )
        try sink.printHarnessRunError(error)
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
      """
    )
  }

  /// Cooked stdin via blocking ``readLine()`` on a detached task. Each invocation gets a fresh
  /// session id (and matching `scribe-{uuid}.log` file).
  public static func runInteractive(
    configuration: AgentConfig,
    client: Client,
    systemPrompt: String,
    sink: any ScribeAgentOutput
  ) async throws {
    let sessionId = UUID()
    try await runInteractive(
      configuration: configuration,
      client: client,
      systemPrompt: systemPrompt,
      sink: sink,
      readUserLine: {
        await Task.detached(priority: .userInitiated) { readLine() }.value
      },
      initialConversation: nil,
      onConversationPersist: nil,
      prepareModelTurnStart: {},
      shouldAbortTurn: { false },
      log: configuration.makeSessionLogger(sessionId: sessionId)
    )
  }

  /// One user turn over stdin/stdout JSON; suitable for subprocess nesting (agents calling `scribe agent`).
  public static func runAgentIPC(
    configuration: AgentConfig,
    client: Client,
    systemPrompt: String,
    request: ScribeAgentRequest,
    sink: any ScribeAgentOutput
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
    let harness = AgentHarness(
      output: sink,
      client: client,
      model: configuration.agentModel,
      maxToolRounds: configuration.agentMaxToolRounds
    )
    let sessionId = UUID()
    let ipcLog = configuration.makeSessionLogger(sessionId: sessionId)
    ipcLog.notice(
      """
      event=ipc.session.start \
      session_id=\(sessionId.uuidString) \
      message_chars=\(request.message.count) \
      max_tool_rounds=\(configuration.agentMaxToolRounds) \
      model=\(configuration.agentModel)
      """
    )
    do {
      let outcome = try await harness.runModelTurn(
        messages: &history, logger: ipcLog)
      if outcome == .hitToolRoundLimit {
        ipcLog.notice(
          """
          event=ipc.session.end \
          status=tool-round-limit \
          limit=\(configuration.agentMaxToolRounds)
          """
        )
        return .failure(
          "Stopped after reaching the configured tool round limit (\(configuration.agentMaxToolRounds))."
        )
      }
      let text = ChatHistory.lastAssistantText(from: history) ?? ""
      ipcLog.notice(
        """
        event=ipc.session.end \
        status=ok \
        assistant_chars=\(text.count)
        """
      )
      return .success(assistant: text)
    } catch let e as AgentAPIError {
      ipcLog.error(
        """
        event=ipc.session.end \
        status=error \
        err="\(e.errorDescription ?? String(describing: e))"
        """
      )
      return .failure(e.errorDescription ?? String(describing: e))
    } catch {
      ipcLog.error(
        """
        event=ipc.session.end \
        status=error \
        err="\(String(describing: error))"
        """
      )
      return .failure(String(describing: error))
    }
  }
}
