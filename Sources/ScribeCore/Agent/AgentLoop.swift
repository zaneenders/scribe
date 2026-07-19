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
      let detail = scribeError.errorDescription ?? String(describing: scribeError)
      guard
        let reason = rollbackContextOverflow(
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

    case .incomplete(let reason):
      emit(.boundary(.turnEnd(round: round, outcome: .incomplete(reason: reason))))
      commit(&currentContext.messages, &newMessages, roundBuffer)
      outcome = .incomplete(reason: reason)
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
  case incomplete(reason: String?)
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
      "request_profile": "\(String(describing: config.requestProfile))",
      "max_completion_tokens": "\(effectiveMaxCompletionTokens(config).map(String.init(describing:)) ?? "nil")",
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
        "finish_reason": "\(turn.finishReason ?? "missing")",
        "max_completion_tokens": "\(effectiveMaxCompletionTokens(config).map(String.init(describing:)) ?? "nil")",
        "answer_chars": "\(turn.text.count)",
        "reasoning_chars": "\(turn.reasoningText.count)",
        "tool_calls": "\(toolInvocations.count)",
        "tps": "\(tps.map { String(format: "%.1f", $0) } ?? "nil")",
      ])
    emit(.lifecycle(.usage(ScribeUsage(u), tokensPerSecond: tps)))
  }

  let finishReason = turn.finishReason?.trimmingCharacters(in: .whitespacesAndNewlines)
  let normalizedFinishReason = finishReason?.lowercased()
  let isIncomplete = normalizedFinishReason.map { reason in
    reason != "stop" && reason != "tool_calls" && reason != "function_call"
  } ?? false

  if toolInvocations.isEmpty {
    let metadata: Logger.Metadata = [
      "answer_chars": "\(turn.text.count)",
      "reasoning_chars": "\(assistantReasoning?.count ?? 0)",
      "finish_reason": "\(finishReason ?? "missing")",
      "completion_tokens": "\(processor.lastUsage?.completionTokens.map(String.init(describing:)) ?? "nil")",
      "max_completion_tokens": "\(effectiveMaxCompletionTokens(config).map(String.init(describing:)) ?? "nil")",
    ]
    if isIncomplete {
      logger.warning("agent.assistant.incomplete", metadata: metadata)
      return RoundResult(
        assistantMessage: assistantMessage,
        kind: .incomplete(reason: finishReason))
    }
    logger.info("agent.assistant.final", metadata: metadata)
    return RoundResult(assistantMessage: assistantMessage, kind: .completed)
  }

  if isIncomplete {
    logger.warning(
      "agent.assistant.incomplete-with-tools",
      metadata: [
        "finish_reason": "\(finishReason ?? "missing")",
        "tool_count": "\(toolInvocations.count)",
      ])
  }

  return RoundResult(assistantMessage: assistantMessage, kind: .toolCalls(toolInvocations))
}

private func effectiveMaxCompletionTokens(_ config: AgentLoopConfig) -> Int? {
  switch config.requestProfile {
  case .standard:
    return nil
  case .moonshotK3, .kimiCode:
    return KimiK3Support.effectiveMaxCompletionTokens(config.maxCompletionTokens)
  }
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
      maxCompletionTokens: effectiveMaxCompletionTokens(config),
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
      maxCompletionTokens: effectiveMaxCompletionTokens(config),
      thinking: .init(_type: .enabled, effort: "max", keep: "all")
    )
  }
}

func isContextLengthError(_ error: ScribeError) -> Bool {
  let detail: String
  switch error {
  case .apiHTTPError(let statusCode, let message, _):
    guard statusCode == 400 || statusCode == 413 else { return false }
    detail = message
  case .generic(let message):
    detail = message
  default:
    return false
  }

  let lower = detail.lowercased()
  return lower.contains("context_length_exceeded")
    || lower.contains("input_too_large")
    || lower.contains("context length")
    || lower.contains("context window")
    || lower.contains("prompt is too long")
    || lower.contains("prompt too long")
    || lower.contains("maximum context")
    || lower.contains("request payload exceeds the limit")
}

func rollbackContextOverflow(
  messages: inout [Components.Schemas.ChatMessage],
  newMessages: inout [Components.Schemas.ChatMessage],
  providerDetail: String
) -> String? {
  let newMessageStart = messages.count - newMessages.count
  var toolIndexesToReplace = Set<Int>()
  var attachmentIndexesToRemove = Set<Int>()

  // Tool-generated attachments are inserted immediately after their tool result. Preserve
  // ordinary multimodal user prompts, but discard attachment messages created by tools.
  for index in messages.indices where isImageMessage(messages[index]) {
    guard index > messages.startIndex, messages[index - 1].role == .tool else { continue }
    attachmentIndexesToRemove.insert(index)
    toolIndexesToReplace.insert(index - 1)
  }

  // Old sessions can contain tool output written before the global result ceiling existed.
  // Compact every conspicuously large result so a single retry has the best chance to fit.
  for index in messages.indices where messages[index].role == .tool {
    if messageTextSize(messages[index]) > 32 * 1024 {
      toolIndexesToReplace.insert(index)
    }
  }

  // Providers do not report which input item crossed the limit. If no obvious attachment or
  // oversized output exists, compact the largest tool result rather than retrying unchanged.
  if toolIndexesToReplace.isEmpty,
    let largest = messages.indices.filter({ messages[$0].role == .tool }).max(by: {
      messageTextSize(messages[$0]) < messageTextSize(messages[$1])
    })
  {
    toolIndexesToReplace.insert(largest)
  }

  guard !toolIndexesToReplace.isEmpty else { return nil }

  let detail = providerDetail.count > 512
    ? String(providerDetail.prefix(512)) + "…"
    : providerDetail
  for index in toolIndexesToReplace {
    let original = messages[index]
    messages[index] = contextOverflowReplacement(original: original, providerDetail: detail)
  }

  for index in attachmentIndexesToRemove.sorted(by: >) {
    messages.remove(at: index)
  }

  // newMessages is the suffix accumulated during this turn. Mirror changes that landed in it
  // so persistence and the retry context remain identical.
  for contextIndex in toolIndexesToReplace where contextIndex >= newMessageStart {
    let newIndex = contextIndex - newMessageStart
    guard newMessages.indices.contains(newIndex) else { continue }
    let original = newMessages[newIndex]
    newMessages[newIndex] = contextOverflowReplacement(
      original: original, providerDetail: detail)
  }
  for contextIndex in attachmentIndexesToRemove.sorted(by: >) where contextIndex >= newMessageStart {
    let newIndex = contextIndex - newMessageStart
    if newMessages.indices.contains(newIndex) { newMessages.remove(at: newIndex) }
  }

  return "model context overflow — compacted \(toolIndexesToReplace.count) tool result(s)"
    + (attachmentIndexesToRemove.isEmpty
      ? "" : " and dropped \(attachmentIndexesToRemove.count) attachment(s)")
}

private func isImageMessage(_ message: Components.Schemas.ChatMessage) -> Bool {
  guard case .case2(let parts) = message.content else { return false }
  return parts.contains { part in
    if case .imageUrl = part { return true }
    return false
  }
}

private func messageTextSize(_ message: Components.Schemas.ChatMessage) -> Int {
  guard case .case1(let text) = message.content else { return 0 }
  return text.utf8.count
}

private func contextOverflowReplacement(
  original: Components.Schemas.ChatMessage,
  providerDetail: String
) -> Components.Schemas.ChatMessage {
  let errorJSON = ToolRegistry.jsonError(
    "tool output exceeded model context window and was removed. provider error: \(providerDetail)"
  )
  return Components.Schemas.ChatMessage(
    role: .tool,
    content: .case1(errorJSON),
    name: original.name,
    toolCalls: nil,
    toolCallId: original.toolCallId
  )
}
