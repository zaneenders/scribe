import Foundation
import Logging
import OpenAPIRuntime
import ScribeLLM
import ScribeLLMAnthropic
import SystemPackage

// MARK: - Anthropic Agent Loop Config

struct AnthropicAgentLoopConfig: Sendable {
  let model: String
  let client: ScribeLLMAnthropic.Client
  let toolExecutor: any ToolExecutor
  let chatTools: [ScribeLLM.Components.Schemas.ChatTool]
  let maxToolRounds: Int
  let workingDirectory: FilePath
  let reasoningEnabled: Bool?
  let hooks: AgentLoopHooks
  let systemPrompt: String?
  let maxTokens: Int
}

// MARK: - Anthropic Agent Loop

private func commit(
  _ context: inout [ScribeLLM.Components.Schemas.ChatMessage],
  _ newMessages: inout [ScribeLLM.Components.Schemas.ChatMessage],
  _ buffer: [ScribeLLM.Components.Schemas.ChatMessage]
) {
  context.append(contentsOf: buffer)
  newMessages.append(contentsOf: buffer)
}

func runAnthropicAgentLoop(
  promptMessages: [ScribeLLM.Components.Schemas.ChatMessage],
  context: AgentContext,
  config: AnthropicAgentLoopConfig,
  emit: @escaping @Sendable (AgentEvent) -> Void,
  logger: Logger,
  abortObserver: some AbortObserver
) async throws -> (messages: [ScribeLLM.Components.Schemas.ChatMessage], termination: TurnOutcome) {
  var currentContext = context
  var newMessages: [ScribeLLM.Components.Schemas.ChatMessage] = []
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
      logger.debug("agent.abort.anthropic", metadata: ["where": "before-http", "round": "\(round)"])
      outcome = .interrupted
      return (newMessages, outcome)
    }

    emit(.boundary(.turnStart(round: round)))

    let roundResult: AnthropicRoundResult
    do {
      roundResult = try await abortObserver.race {
        [currentContext, config, emit, logger, clock, round, abortObserver] in
        try await runSingleAnthropicRound(
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
      logger.notice("agent.abort.anthropic", metadata: ["where": "mid-stream", "round": "\(round)"])
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
      logger.notice("agent.recover.anthropic", metadata: ["reason": "\(reason)"])
      emit(.lifecycle(.recovered(reason: reason)))
      emit(.boundary(.turnEnd(round: round, outcome: .completed)))
      continue
    } catch let scribeError as ScribeError {
      throw scribeError
    } catch {
      logger.error(
        "agent.loop.error.anthropic",
        metadata: [
          "round": "\(round)",
          "partial_messages": "\(newMessages.count)",
          "err": "\(String(describing: error))",
        ])
      emit(.boundary(.turnEnd(round: round, outcome: .error(String(describing: error)))))
      outcome = .error(String(describing: error))
      return (newMessages, outcome)
    }

    var roundBuffer: [ScribeLLM.Components.Schemas.ChatMessage] = [roundResult.assistantMessage]

    if abortObserver.isAborted() {
      logger.debug("agent.abort.anthropic", metadata: ["where": "post-stream-pre-tools", "round": "\(round)"])
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
        logger.notice("agent.turn.tool-round-limit.anthropic", metadata: ["max": "\(config.maxToolRounds)"])
        outcome = .toolRoundLimit(rounds: config.maxToolRounds)
        return (newMessages, outcome)
      }

      logger.info(
        "agent.tool.round.anthropic",
        metadata: [
          "round": "\(round)", "tool_count": "\(invocations.count)",
          "tools": "\(invocations.map(\.name).joined(separator: ","))",
        ])

      for inv in invocations {
        if abortObserver.isAborted() {
          logger.notice("agent.abort.anthropic", metadata: ["where": "pre-tool", "tool": "\(inv.name)", "round": "\(round)"])
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
            result = ToolResult.text(ToolRegistry.jsonError("unknown tool \(name)"))
          } catch {
            result = ToolResult.text(ToolRegistry.jsonError(String(describing: error)))
          }
        }

        let afterDecision = await config.hooks.afterToolCall(resolvedInv, result)
        let finalResult = afterDecision.result
        emit(.boundary(.toolExecutionEnd(name: resolvedInv.name, output: finalResult.text)))
        emit(.tool(.invocation(name: resolvedInv.name, arguments: resolvedInv.arguments, output: finalResult.text)))

        emit(.boundary(.messageStart(role: .tool, round: round)))
        roundBuffer.append(
          ScribeLLM.Components.Schemas.ChatMessage(
            role: .tool, content: .case1(finalResult.text),
            name: nil, toolCalls: nil, toolCallId: resolvedInv.id))
        emit(.boundary(.messageEnd(role: .tool, round: round)))

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

// MARK: - Single Round

private struct AnthropicRoundResult: Sendable {
  let assistantMessage: ScribeLLM.Components.Schemas.ChatMessage
  let kind: AnthropicRoundOutcome
}

private enum AnthropicRoundOutcome: Sendable, Equatable {
  case completed
  case toolCalls([ToolInvocation])
}

private func runSingleAnthropicRound(
  contextMessages: [ScribeLLM.Components.Schemas.ChatMessage],
  config: AnthropicAgentLoopConfig,
  emit: @escaping @Sendable (AgentEvent) -> Void,
  logger: Logger,
  clock: ContinuousClock,
  round: Int,
  abortObserver: some AbortObserver
) async throws -> AnthropicRoundResult {

  emit(.boundary(.messageStart(role: .assistant, round: round)))

  // Convert messages to Anthropic format
  let scribeMessages = contextMessages.toScribeMessages()
  let anthropicMessages = toAnthropicMessages(scribeMessages)
  let systemPayload = extractSystemPrompt(scribeMessages) ?? config.systemPrompt.map { .case1($0) }

  // Convert tools to Anthropic format
  let anthropicTools: [ScribeLLMAnthropic.Components.Schemas.Tool]? = config.chatTools.isEmpty ? nil : config.chatTools.map { ct in
    // Convert OpenAI ChatTool parameters (additionalProperties) to Anthropic Tool input_schema
    var inputSchema = ScribeLLMAnthropic.Components.Schemas.Tool.InputSchemaPayload(_type: .object)
    inputSchema.properties = .init(additionalProperties: ct.function.parameters.additionalProperties)
    return ScribeLLMAnthropic.Components.Schemas.Tool(
      name: ct.function.name,
      description: ct.function.description,
      inputSchema: inputSchema
    )
  }

  let requestBody = ScribeLLMAnthropic.Components.Schemas.CreateMessageRequest(
    model: config.model,
    messages: anthropicMessages,
    system: systemPayload,
    maxTokens: config.maxTokens,
    stream: true,
    temperature: nil,
    tools: anthropicTools,
    toolChoice: nil
  )

  let httpStart = clock.now
  logger.info(
    "agent.http.request.anthropic",
    metadata: [
      "messages": "\(requestBody.messages.count)",
      "model": "\(config.model)",
    ])

  let response = try await config.client.createMessage(body: .json(requestBody))

  let httpBody: HTTPBody
  switch response {
  case .ok(let ok):
    logger.debug(
      "agent.http.response.anthropic",
      metadata: ["status": "200", "elapsed": "\(clock.now - httpStart)"])
    httpBody = try ok.body.textEventStream
  case .clientError(statusCode: let code, let error):
    var detail = ""
    if case .json(let errorResponse) = error.body {
      switch errorResponse.error {
        case .apiError(let e): detail = e.message
        case .authenticationError(let e): detail = e.message
        case .invalidRequestError(let e): detail = e.message
        case .notFoundError(let e): detail = e.message
        case .overloadedError(let e): detail = e.message
        case .permissionError(let e): detail = e.message
        case .rateLimitError(let e): detail = e.message
        }
      }
    let hint: String? = code == 401 ? " Check your API key." : nil
    logger.warning("agent.http.response.anthropic", metadata: ["status": "\(code)", "detail": "\(detail)"])
    throw ScribeError.apiHTTPError(statusCode: code, detail: detail, hint: hint)
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
    let hint: String? = {
      if code == 401 {
        return " Check your API key."
      }
      if code == 404 {
        return " Check the base URL — Anthropic Messages API is at /v1/messages."
      }
      return nil
    }()
    let detailSnippet = detail.count > 512 ? String(detail.prefix(512)) + "…(\(detail.count) chars)" : detail
    let level: Logger.Level = code >= 500 ? .error : .warning
    logger.log(
      level: level,
      "agent.http.response.anthropic",
      metadata: [
        "status": "\(code)",
        "body_snippet": "\(detailSnippet.replacingOccurrences(of: "\"", with: "\\\""))",
      ])
    throw ScribeError.apiHTTPError(statusCode: code, detail: detail, hint: hint)
  }

  var turn = AnthropicAssistantTurn()
  var processor = AnthropicStreamProcessor(
    onEvent: emit,
    logger: logger,
    abortObserver: abortObserver,
    streamWallStart: clock.now
  )
  try await processor.process(httpBody: httpBody, httpStart: httpStart, turn: &turn)

  let toolInvocations = turn.resolvedToolCalls()
  let assistantText = turn.resolvedText()
  let assistantContent: ScribeLLM.Components.Schemas.ChatMessage.ContentPayload? =
    assistantText.isEmpty ? nil : .case1(assistantText)
  let assistantReasoning = turn.resolvedReasoning()

  let assistantMessage = ScribeLLM.Components.Schemas.ChatMessage(
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
    reasoningContent: assistantReasoning.isEmpty ? nil : assistantReasoning
  )
  emit(.boundary(.messageEnd(role: .assistant, round: round)))

  // Emit usage
  if let u = processor.lastUsage {
    let genStart = processor.firstStreamContentAt ?? processor.streamWallStart
    let genSec = (clock.now - genStart) / .seconds(1)
    let tps: Double? = {
      guard u.outputTokens > 0 else { return nil }
      return Double(u.outputTokens) / max(0.001, genSec)
    }()
    let completionUsage = ScribeLLM.Components.Schemas.CompletionUsage(
      promptTokens: u.inputTokens,
      completionTokens: u.outputTokens,
      totalTokens: u.inputTokens + u.outputTokens,
      promptTokensDetails: nil,
      completionTokensDetails: nil
    )
    logger.debug(
      "agent.stream.end.anthropic",
      metadata: [
        "chunks": "\(processor.decodedChunkCount)",
        "skipped": "\(processor.skippedChunkCount)",
        "prompt_tokens": "\(u.inputTokens)",
        "completion_tokens": "\(u.outputTokens)",
        "tps": "\(tps.map { String(format: "%.1f", $0) } ?? "nil")",
      ])
    emit(.lifecycle(.usage(ScribeUsage(completionUsage), tokensPerSecond: tps)))
  }

  if toolInvocations.isEmpty {
    logger.info(
      "agent.assistant.final.anthropic",
      metadata: [
        "answer_chars": "\(assistantText.count)",
        "reasoning_chars": "\(assistantReasoning.count)",
      ])
    return AnthropicRoundResult(assistantMessage: assistantMessage, kind: .completed)
  }

  return AnthropicRoundResult(assistantMessage: assistantMessage, kind: .toolCalls(toolInvocations))
}

// MARK: - Helpers

/// Extract system prompt from an array of ScribeMessages.
private func extractSystemPrompt(_ messages: [ScribeMessage]) -> ScribeLLMAnthropic.Components.Schemas.CreateMessageRequest.SystemPayload? {
  let systemText = messages
    .filter { $0.role == .system }
    .map(\.content)
    .joined(separator: "\n")
  return toAnthropicSystem(systemText)
}
