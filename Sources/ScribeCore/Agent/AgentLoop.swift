import Foundation
import Logging
import OpenAPIRuntime
import ScribeLLM
import SystemPackage

struct AgentContext: Sendable {
  var messages: [Components.Schemas.ChatMessage]
}

struct AgentLoopConfig: Sendable {
  let model: String
  let client: Client

  let toolExecutor: any ToolExecutor

  let chatTools: [Components.Schemas.ChatTool]
  let temperature: Double
  let maxToolRounds: Int
  let workingDirectory: FilePath
  let reasoningEnabled: Bool?
  let hooks: AgentLoopHooks
  let requestProfile: ChatCompletionRequestProfile
  let maxCompletionTokens: Int?

  init(
    model: String,
    client: Client,
    toolExecutor: any ToolExecutor,
    chatTools: [Components.Schemas.ChatTool],
    temperature: Double,
    maxToolRounds: Int,
    workingDirectory: FilePath,
    reasoningEnabled: Bool?,
    hooks: AgentLoopHooks,
    requestProfile: ChatCompletionRequestProfile = .standard,
    maxCompletionTokens: Int? = nil
  ) {
    self.model = model
    self.client = client
    self.toolExecutor = toolExecutor
    self.chatTools = chatTools
    self.temperature = temperature
    self.maxToolRounds = maxToolRounds
    self.workingDirectory = workingDirectory
    self.reasoningEnabled = reasoningEnabled
    self.hooks = hooks
    self.requestProfile = requestProfile
    self.maxCompletionTokens = maxCompletionTokens
  }
}

func runAgentLoop(
  promptMessages: [Components.Schemas.ChatMessage],
  context: AgentContext,
  config: AgentLoopConfig,
  emit: @escaping @Sendable (AgentEvent) -> Void,
  logger: Logger,
  abortObserver: some AbortObserver
) async throws -> (messages: [Components.Schemas.ChatMessage], termination: TurnOutcome) {
  var currentContext = context
  var newMessages: [Components.Schemas.ChatMessage] = []
  var outcome: TurnOutcome = .completed

  emit(.boundary(.agentStart))
  defer { emit(.boundary(.agentEnd(outcome))) }

  for msg in promptMessages {
    emit(.boundary(.messageStart(role: .user, round: 0)))
    currentContext.messages.append(msg)
    newMessages.append(msg)
    emit(.boundary(.messageEnd(role: .user, round: 0)))
  }

  let clock = ContinuousClock()
  var round = 0
  var attemptedRecovery = false

  while true {
    round += 1
    if abortObserver.isAborted() {
      logger.debug("agent.abort", metadata: ["where": "before-http", "round": "\(round)"])
      outcome = .interrupted
      return (newMessages, outcome)
    }

    emit(.boundary(.turnStart(round: round)))

    let roundResult: RoundResult
    do {
      roundResult = try await abortObserver.race {
        [currentContext, config, emit, logger, round, abortObserver] in
        try await runSingleRound(
          contextMessages: currentContext.messages,
          config: config,
          emit: emit,
          logger: logger,
          clock: clock,
          round: round,
          abortObserver: abortObserver
        )
      }
    } catch is AgentTurnInterruptedError {
      logger.notice("agent.abort", metadata: ["where": "mid-stream", "round": "\(round)"])
      emit(.boundary(.turnEnd(round: round, outcome: .interrupted)))
      outcome = .interrupted
      return (newMessages, outcome)
    } catch let scribeError as ScribeError where !attemptedRecovery && isContextLengthError(scribeError) {
      guard case .apiHTTPError(_, let detail, _) = scribeError else {
        throw scribeError
      }
      guard
        let reason = rollbackAttachmentOverflow(
          messages: &currentContext.messages,
          newMessages: &newMessages,
          providerDetail: detail)
      else {
        throw scribeError
      }
      attemptedRecovery = true
      logger.notice("agent.recover", metadata: ["reason": "\(reason)"])
      emit(.lifecycle(.recovered(reason: reason)))
      emit(.boundary(.turnEnd(round: round, outcome: .completed)))
      continue
    } catch let scribeError as ScribeError {
      // Non-recoverable ScribeErrors (apiHTTPError, etc.) — propagate
      // so callers can inspect the specific error type.
      throw scribeError
    } catch {
      logger.error(
        "agent.loop.error",
        metadata: [
          "round": "\(round)",
          "partial_messages": "\(newMessages.count)",
          "err": "\(String(describing: error))",
        ])
      emit(.boundary(.turnEnd(round: round, outcome: .error(String(describing: error)))))
      outcome = .error(String(describing: error))
      return (newMessages, outcome)
    }

    var roundBuffer: [Components.Schemas.ChatMessage] = [roundResult.assistantMessage]

    if abortObserver.isAborted() {
      logger.debug("agent.abort", metadata: ["where": "post-stream-pre-tools", "round": "\(round)"])
      emit(.boundary(.turnEnd(round: round, outcome: .interrupted)))
      outcome = .interrupted
      return (newMessages, outcome)
    }

    switch roundResult.kind {
    case .completed:
      emit(.boundary(.turnEnd(round: round, outcome: .completed)))
      commit(&currentContext.messages, &newMessages, roundBuffer)
      outcome = .completed
      return (newMessages, outcome)

    case .toolCalls(let invocations):
      emit(.boundary(.turnEnd(round: round, outcome: .toolCalls(count: invocations.count))))
      if round >= config.maxToolRounds {
        logger.notice("agent.turn.tool-round-limit", metadata: ["max": "\(config.maxToolRounds)"])
        outcome = .toolRoundLimit(rounds: config.maxToolRounds)
        return (newMessages, outcome)
      }

      logger.info(
        "agent.tool.round",
        metadata: [
          "round": "\(round)", "tool_count": "\(invocations.count)",
          "tools": "\(invocations.map(\.name).joined(separator: ","))",
        ])

      for inv in invocations {
        if abortObserver.isAborted() {
          logger.notice(
            "agent.abort",
            metadata: ["where": "pre-tool", "tool": "\(inv.name)", "round": "\(round)"])
          outcome = .interrupted
          return (newMessages, outcome)
        }

        let beforeDecision = await config.hooks.beforeToolCall(inv)
        let resolvedInv: ToolInvocation
        let preflightResult: ToolResult?
        switch beforeDecision {
        case .proceed(let rewritten):
          resolvedInv = rewritten
          preflightResult = nil
        case .block(let reason):
          resolvedInv = inv
          preflightResult = ToolResult.text(ToolRegistry.jsonError(reason))
        }

        emit(.boundary(.toolExecutionStart(name: resolvedInv.name, arguments: resolvedInv.arguments)))

        let result: ToolResult
        if let preflightResult {
          result = preflightResult
        } else {
          do {
            result = try await config.toolExecutor.execute(
              resolvedInv,
              workingDirectory: config.workingDirectory,
              logger: logger,
              abort: abortObserver)
          } catch is AgentTurnInterruptedError {
            outcome = .interrupted
            return (newMessages, outcome)
          } catch let ScribeError.toolUnknown(name) {
            logger.warning("agent.tool.unknown", metadata: ["tool": "\(name)", "round": "\(round)"])
            result = ToolResult.text(ToolRegistry.jsonError("unknown tool \(name)"))
          } catch {
            logger.warning(
              "agent.tool.executor.error",
              metadata: [
                "tool": "\(resolvedInv.name)", "round": "\(round)",
                "err": "\(String(describing: error).replacingOccurrences(of: "\"", with: "\\\""))",
              ])
            result = ToolResult.text(ToolRegistry.jsonError(String(describing: error)))
          }
        }

        let afterDecision = await config.hooks.afterToolCall(resolvedInv, result)
        let finalResult = afterDecision.result
        emit(.boundary(.toolExecutionEnd(name: resolvedInv.name, output: finalResult.text)))
        emit(.tool(.invocation(name: resolvedInv.name, arguments: resolvedInv.arguments, output: finalResult.text)))
        for warning in finalResult.warnings {
          emit(.tool(.warning(warning)))
        }

        emit(.boundary(.messageStart(role: .tool, round: round)))
        roundBuffer.append(
          Components.Schemas.ChatMessage(
            role: .tool, content: .case1(finalResult.text),
            name: nil, toolCalls: nil, toolCallId: resolvedInv.id))
        emit(.boundary(.messageEnd(role: .tool, round: round)))

        for attachment in finalResult.attachments {
          logger.info(
            "agent.tool.attachment.inject",
            metadata: [
              "round": "\(round)",
              "tool": "\(resolvedInv.name)",
              "mime_type": "\(attachment.mimeType)",
              "base64_chars": "\(attachment.base64.count)",
              "source_path": "\(attachment.sourcePath ?? "nil")",
            ])
          let parts: [ScribeContentPart] = [
            .text((attachment.sourcePath ?? attachment.filename).map { "\($0):" } ?? "Attached media:"),
            .image(url: attachment.dataUri, detail: nil),
          ]
          emit(.boundary(.messageStart(role: .user, round: round)))
          roundBuffer.append(ScribeMessage(role: .user, contentParts: parts).toChatMessage())
          emit(.boundary(.messageEnd(role: .user, round: round)))
        }

        if afterDecision.terminate {
          commit(&currentContext.messages, &newMessages, roundBuffer)
          outcome = .completed
          return (newMessages, outcome)
        }
      }

      commit(&currentContext.messages, &newMessages, roundBuffer)
    }
  }
}

private func commit(
  _ context: inout [Components.Schemas.ChatMessage],
  _ newMessages: inout [Components.Schemas.ChatMessage],
  _ buffer: [Components.Schemas.ChatMessage]
) {
  context.append(contentsOf: buffer)
  newMessages.append(contentsOf: buffer)
}

private struct RoundResult: Sendable {
  let assistantMessage: Components.Schemas.ChatMessage
  let kind: RoundOutcome
}

private enum RoundOutcome: Sendable, Equatable {
  case completed
  case toolCalls([ToolInvocation])
}

private func runSingleRound(
  contextMessages: [Components.Schemas.ChatMessage],
  config: AgentLoopConfig,
  emit: @escaping @Sendable (AgentEvent) -> Void,
  logger: Logger,
  clock: ContinuousClock,
  round: Int,
  abortObserver: some AbortObserver
) async throws -> RoundResult {

  emit(.boundary(.messageStart(role: .assistant, round: round)))

  let requestBody = try makeChatCompletionRequest(
    config: config,
    messages: contextMessages
  )

  let httpStart = clock.now
  logger.info(
    "agent.http.request",
    metadata: [
      "messages": "\(requestBody.messages.count)",
      "reasoning_enabled": "\(String(describing: config.reasoningEnabled))",
    ])
  let response = try await config.client.createChatCompletion(body: .json(requestBody))

  let httpBody: HTTPBody
  switch response {
  case .ok(let ok):
    logger.debug(
      "agent.http.response",
      metadata: [
        "status": "200",
        "elapsed": "\(clock.now - httpStart)",
      ])
    httpBody = try ok.body.textEventStream
  case .undocumented(statusCode: let code, let payload):
    var detail = ""
    if let body = payload.body {
      do {
        let chunk = try await HTTPBody.ByteChunk(collecting: body, upTo: 4096)
        detail = String(decoding: chunk, as: UTF8.self)
      } catch {
        detail = "(response body exceeds 4096 bytes — truncated)"
      }
    }
    let hint: String = {
      let d = detail.lowercased()
      if code == 401, config.requestProfile == .moonshotK3 || config.requestProfile == .kimiCode {
        return " Check your API key matches api.baseUrl: Kimi Code keys require https://api.kimi.com/coding; Moonshot platform keys require https://api.moonshot.ai."
      }
      if d.contains("model"), d.contains("not found") {
        return " The configured model was not found."
      }
      if code == 404 {
        return " Set api.baseUrl to the host only (no /v1)."
      }
      return ""
    }()
    let detailSnippet = detail.count > 512 ? String(detail.prefix(512)) + "…(\(detail.count) chars)" : detail
    let level: Logger.Level = code >= 500 ? .error : .warning
    logger.log(
      level: level,
      "agent.http.response",
      metadata: [
        "status": "\(code)",
        "body_snippet": "\(detailSnippet.replacingOccurrences(of: "\"", with: "\\\""))",
      ])
    throw ScribeError.apiHTTPError(statusCode: code, detail: detail, hint: hint.isEmpty ? nil : hint)
  }

  var turn = StreamedAssistantTurn()
  var processor = StreamProcessor(
    onEvent: emit,
    logger: logger,
    abortObserver: abortObserver,
    streamWallStart: clock.now
  )
  try await processor.process(httpBody: httpBody, httpStart: httpStart, turn: &turn)

  let toolInvocations = turn.resolvedToolCalls()
  let assistantContent: Components.Schemas.ChatMessage.ContentPayload? =
    turn.text.isEmpty ? nil : .case1(turn.text)
  let assistantReasoning = turn.reasoningText.isEmpty ? nil : turn.reasoningText

  let assistantMessage = Components.Schemas.ChatMessage(
    role: .assistant,
    content: assistantContent,
    name: nil,
    toolCalls: toolInvocations.isEmpty
      ? nil
      : toolInvocations.map { inv in
        .init(
          id: inv.id,
          _type: "function",
          function: .init(name: inv.name, arguments: inv.arguments))
      },
    toolCallId: nil,
    reasoningContent: assistantReasoning
  )
  emit(.boundary(.messageEnd(role: .assistant, round: round)))

  if let u = processor.lastUsage {
    let genStart = processor.firstStreamContentAt ?? processor.streamWallStart
    let genSec = (clock.now - genStart) / .seconds(1)
    let tps: Double? = {
      guard let c = u.completionTokens, c > 0 else { return nil }
      return Double(c) / max(0.001, genSec)
    }()
    logger.debug(
      "agent.stream.end",
      metadata: [
        "chunks": "\(processor.decodedChunkCount)",
        "skipped": "\(processor.skippedChunkCount)",
        "prompt_tokens": "\(u.promptTokens.map(String.init(describing:)) ?? "nil")",
        "completion_tokens": "\(u.completionTokens.map(String.init(describing:)) ?? "nil")",
        "tps": "\(tps.map { String(format: "%.1f", $0) } ?? "nil")",
      ])
    emit(.lifecycle(.usage(ScribeUsage(u), tokensPerSecond: tps)))
  }

  if toolInvocations.isEmpty {
    logger.info(
      "agent.assistant.final",
      metadata: [
        "answer_chars": "\(turn.text.count)",
        "reasoning_chars": "\(assistantReasoning?.count ?? 0)",
      ])
    return RoundResult(assistantMessage: assistantMessage, kind: .completed)
  }

  return RoundResult(assistantMessage: assistantMessage, kind: .toolCalls(toolInvocations))
}

private func makeChatCompletionRequest(
  config: AgentLoopConfig,
  messages: [Components.Schemas.ChatMessage]
) throws -> Components.Schemas.CreateChatCompletionRequest {
  let tools = config.chatTools.isEmpty ? nil : config.chatTools
  switch config.requestProfile {
  case .standard:
    return Components.Schemas.CreateChatCompletionRequest(
      model: config.model,
      messages: messages,
      stream: true,
      temperature: Float(config.temperature),
      maxTokens: nil,
      tools: tools,
      toolChoice: nil,
      streamOptions: .init(includeUsage: true),
      reasoning: config.reasoningEnabled == nil
        ? nil : Components.Schemas.ChatCompletionReasoning(enabled: config.reasoningEnabled),
      reasoningEffort: nil,
      maxCompletionTokens: nil,
      thinking: nil
    )
  case .moonshotK3:
    try KimiK3Support.validateMessages(messages)
    return Components.Schemas.CreateChatCompletionRequest(
      model: config.model,
      messages: messages,
      stream: true,
      temperature: nil,
      maxTokens: nil,
      tools: tools,
      toolChoice: nil,
      streamOptions: .init(includeUsage: true),
      reasoning: nil,
      reasoningEffort: .max,
      maxCompletionTokens: config.maxCompletionTokens,
      thinking: nil
    )
  case .kimiCode:
    try KimiK3Support.validateMessages(messages)
    return Components.Schemas.CreateChatCompletionRequest(
      model: config.model,
      messages: messages,
      stream: true,
      temperature: nil,
      maxTokens: nil,
      tools: tools,
      toolChoice: nil,
      streamOptions: .init(includeUsage: true),
      reasoning: nil,
      reasoningEffort: nil,
      maxCompletionTokens: config.maxCompletionTokens,
      thinking: .init(_type: .enabled, effort: "max", keep: nil)
    )
  }
}

func isContextLengthError(_ error: ScribeError) -> Bool {
  guard case .apiHTTPError(let statusCode, let detail, _) = error, statusCode == 400 else {
    return false
  }
  let lower = detail.lowercased()
  return lower.contains("context length")
    || lower.contains("prompt is too long")
    || lower.contains("prompt too long")
    || lower.contains("maximum context")
}

func rollbackAttachmentOverflow(
  messages: inout [Components.Schemas.ChatMessage],
  newMessages: inout [Components.Schemas.ChatMessage],
  providerDetail: String
) -> String? {

  var droppedAttachments = 0
  while let last = messages.last,
    last.role == .user,
    case .case2 = last.content
  {
    messages.removeLast()
    if !newMessages.isEmpty, newMessages.last?.role == .user,
      case .case2 = newMessages.last?.content
    {
      newMessages.removeLast()
    }
    droppedAttachments += 1
  }
  guard droppedAttachments > 0 else { return nil }

  guard let toolMsgIdx = messages.lastIndex(where: { $0.role == .tool }),
    toolMsgIdx == messages.count - 1
  else { return nil }

  let original = messages[toolMsgIdx]
  let errorJSON = ToolRegistry.jsonError(
    "tool output exceeded model context window — attachment(s) discarded. provider error: \(providerDetail)"
  )
  let replacement = Components.Schemas.ChatMessage(
    role: .tool,
    content: .case1(errorJSON),
    name: original.name,
    toolCalls: nil,
    toolCallId: original.toolCallId
  )
  messages[toolMsgIdx] = replacement
  if let newIdx = newMessages.lastIndex(where: { $0.role == .tool && $0.toolCallId == original.toolCallId }) {
    newMessages[newIdx] = replacement
  }
  return "tool output exceeded model context — dropped \(droppedAttachments) attachment(s)"
}
