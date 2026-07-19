import Foundation
import Logging
import OpenAPIRuntime
import ScribeLLM
import ScribeLLMCodex
import SystemPackage

// MARK: - Shared Helpers

struct CodexToolCallIdentifiers: Equatable {
  private static let separator: Character = "|"

  let callID: String
  let itemID: String

  init(callID: String, itemID: String) {
    self.callID = callID
    self.itemID = itemID
  }

  init(encoded: String) {
    let parts = encoded.split(separator: Self.separator, maxSplits: 1, omittingEmptySubsequences: false)
    callID = String(parts[0])
    itemID = parts.count == 2 ? String(parts[1]) : encoded
  }

  var encoded: String {
    "\(callID)\(Self.separator)\(itemID)"
  }
}

private func commit(
  _ context: inout [ScribeLLM.Components.Schemas.ChatMessage],
  _ newMessages: inout [ScribeLLM.Components.Schemas.ChatMessage],
  _ buffer: [ScribeLLM.Components.Schemas.ChatMessage]
) {
  context.append(contentsOf: buffer)
  newMessages.append(contentsOf: buffer)
}

// MARK: - Codex Agent Loop

/// Configuration for the Codex agent loop.
struct CodexAgentLoopConfig: Sendable {
  let model: String
  let client: ScribeLLMCodex.Client
  let toolExecutor: any ToolExecutor
  let chatTools: [ScribeLLM.Components.Schemas.ChatTool]
  let maxToolRounds: Int
  let workingDirectory: FilePath
  let reasoningEnabled: Bool?
  let hooks: AgentLoopHooks
  let contextWindow: Int

  init(
    model: String,
    client: ScribeLLMCodex.Client,
    toolExecutor: any ToolExecutor,
    chatTools: [ScribeLLM.Components.Schemas.ChatTool],
    maxToolRounds: Int,
    workingDirectory: FilePath,
    reasoningEnabled: Bool?,
    hooks: AgentLoopHooks,
    contextWindow: Int = 0
  ) {
    self.model = model
    self.client = client
    self.toolExecutor = toolExecutor
    self.chatTools = chatTools
    self.maxToolRounds = maxToolRounds
    self.workingDirectory = workingDirectory
    self.reasoningEnabled = reasoningEnabled
    self.hooks = hooks
    self.contextWindow = contextWindow
  }
}

/// Runs the agent loop against the Codex (ChatGPT subscription) API.
func runCodexAgentLoop(
  promptMessages: [ScribeLLM.Components.Schemas.ChatMessage],
  context: AgentContext,
  config: CodexAgentLoopConfig,
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
      outcome = .interrupted
      return (newMessages, outcome)
    }

    emit(.boundary(.turnStart(round: round)))

    do {
      if let reason = try enforceRequestBudget(
        messages: &currentContext.messages,
        newMessages: &newMessages,
        tools: config.chatTools,
        contextWindow: config.contextWindow)
      {
        logger.notice(
          "agent.request.preflight.compacted.codex",
          metadata: ["round": "\(round)", "reason": "\(reason)"])
        emit(.lifecycle(.recovered(reason: reason)))
      }

      let roundResult = try await abortObserver.race {
        [currentContext, config, emit, logger, clock, round, abortObserver] in
        try await runSingleCodexRound(
          contextMessages: currentContext.messages,
          config: config,
          emit: emit,
          logger: logger,
          clock: clock,
          round: round,
          abortObserver: abortObserver
        )
      }

      var roundBuffer: [ScribeLLM.Components.Schemas.ChatMessage] = [roundResult.assistantMessage]

      if abortObserver.isAborted() {
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
          outcome = .toolRoundLimit(rounds: config.maxToolRounds)
          return (newMessages, outcome)
        }

        logger.info("agent.tool.round.codex", metadata: ["round": "\(round)", "tool_count": "\(invocations.count)"])

        for inv in invocations {
          if abortObserver.isAborted() {
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
          for warning in finalResult.warnings {
            emit(.tool(.warning(warning)))
          }

          emit(.boundary(.messageStart(role: .tool, round: round)))
          roundBuffer.append(
            ScribeLLM.Components.Schemas.ChatMessage(
              role: .tool, content: .case1(finalResult.text),
              name: nil, toolCalls: nil, toolCallId: resolvedInv.id))
          emit(.boundary(.messageEnd(role: .tool, round: round)))

          for attachment in finalResult.attachments {
            logger.info(
              "agent.tool.attachment.inject.codex",
              metadata: [
                "round": "\(round)",
                "tool": "\(resolvedInv.name)",
                "mime_type": "\(attachment.mimeType)",
                "base64_chars": "\(attachment.base64.count)",
                "source_path": "\(attachment.sourcePath ?? "nil")",
              ])
            emit(.boundary(.messageStart(role: .user, round: round)))
            roundBuffer.append(codexAttachmentMessage(attachment))
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
    } catch is AgentTurnInterruptedError {
      emit(.boundary(.turnEnd(round: round, outcome: .interrupted)))
      outcome = .interrupted
      return (newMessages, outcome)
    } catch let scribeError as ScribeError
      where !attemptedRecovery && isContextLengthError(scribeError)
    {
      let detail = scribeError.errorDescription ?? String(describing: scribeError)
      guard
        let reason = rollbackContextOverflow(
          messages: &currentContext.messages,
          newMessages: &newMessages,
          providerDetail: detail)
      else {
        outcome = .error(scribeError.errorDescription ?? String(describing: scribeError))
        throw scribeError
      }
      attemptedRecovery = true
      logger.notice("agent.recover.codex", metadata: ["round": "\(round)", "reason": "\(reason)"])
      emit(.lifecycle(.recovered(reason: reason)))
      emit(.boundary(.turnEnd(round: round, outcome: .completed)))
      continue
    } catch {
      let description =
        (error as? LocalizedError)?.errorDescription
        ?? String(describing: error)
      logger.error(
        "agent.loop.error.codex",
        metadata: ["round": "\(round)", "err": "\(description)"])
      emit(.boundary(.turnEnd(round: round, outcome: .error(description))))
      outcome = .error(description)
      return (newMessages, outcome)
    }
  }
}

// MARK: - Single Round

private struct CodexRoundResult: Sendable {
  let assistantMessage: ScribeLLM.Components.Schemas.ChatMessage
  let kind: CodexRoundOutcome
}

private enum CodexRoundOutcome: Sendable, Equatable {
  case completed
  case incomplete(reason: String?)
  case toolCalls([ToolInvocation])
}

private func runSingleCodexRound(
  contextMessages: [ScribeLLM.Components.Schemas.ChatMessage],
  config: CodexAgentLoopConfig,
  emit: @escaping @Sendable (AgentEvent) -> Void,
  logger: Logger,
  clock: ContinuousClock,
  round: Int,
  abortObserver: some AbortObserver
) async throws -> CodexRoundResult {

  emit(.boundary(.messageStart(role: .assistant, round: round)))

  // Build Codex request from chat messages
  let input = convertChatMessagesToCodexInput(contextMessages)
  let codexTools = convertToCodexTools(config.chatTools)

  let requestBody = ScribeLLMCodex.Components.Schemas.CreateCodexResponseRequest(
    model: config.model,
    store: false,
    stream: true,
    instructions: nil,
    previousResponseId: nil,
    input: input,
    tools: codexTools,
    toolChoice: .auto,
    parallelToolCalls: true,
    temperature: nil,
    reasoning: config.reasoningEnabled == true
      ? {
        var r = ScribeLLMCodex.Components.Schemas.CodexReasoning()
        r.effort = .medium
        return r
      }()
      : nil,
    serviceTier: nil,
    text: nil,
    include: ["reasoning.encrypted_content"],
    promptCacheKey: nil
  )

  let requestMetrics = codexRequestMetrics(contextMessages)
  let httpStart = clock.now
  logger.info(
    "agent.http.request.codex",
    metadata: [
      "model": "\(config.model)",
      "round": "\(round)",
      "messages": "\(contextMessages.count)",
      "input_items": "\(input?.count ?? 0)",
      "tools": "\(codexTools?.count ?? 0)",
      "text_chars": "\(requestMetrics.textChars)",
      "image_count": "\(requestMetrics.imageCount)",
      "image_uri_chars": "\(requestMetrics.imageURIChars)",
      "tool_call_count": "\(requestMetrics.toolCallCount)",
      "tool_output_chars": "\(requestMetrics.toolOutputChars)",
    ])

  let response = try await config.client.createCodexResponse(body: .json(requestBody))

  let httpBody: HTTPBody
  switch response {
  case .ok(let ok):
    logger.debug(
      "agent.http.response.codex",
      metadata: [
        "status": "200",
        "round": "\(round)",
        "request_elapsed_ms": "\((clock.now - httpStart) / .milliseconds(1))",
      ])
    httpBody = try ok.body.textEventStream
  case .undocumented(statusCode: let code, let payload):
    var detail = ""
    if let body = payload.body {
      do {
        let chunk = try await HTTPBody.ByteChunk(collecting: body, upTo: 4096)
        detail = String(decoding: chunk, as: UTF8.self)
      } catch {
        detail = "(unable to read error body)"
      }
    }
    logger.warning("agent.http.response.codex", metadata: ["status": "\(code)"])
    throw ScribeError.apiHTTPError(statusCode: code, detail: detail, hint: nil)
  }

  var turn = CodexAssistantTurn()
  var processor = CodexStreamProcessor(
    onEvent: emit,
    logger: logger,
    abortObserver: abortObserver,
    streamWallStart: clock.now
  )
  try await processor.process(httpBody: httpBody, httpStart: httpStart, turn: &turn)

  let toolInvocations = turn.resolvedToolCalls()
  let assistantContent: ScribeLLM.Components.Schemas.ChatMessage.ContentPayload? =
    turn.text.isEmpty ? nil : .case1(turn.text)
  let assistantReasoning = turn.reasoningText.isEmpty ? nil : turn.reasoningText

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
    reasoningContent: assistantReasoning
  )
  emit(.boundary(.messageEnd(role: .assistant, round: round)))

  if let u = processor.lastUsage {
    // Usage output tokens include hidden reasoning, so measure from the start of the
    // response stream rather than the first visible text/tool delta.
    let genSec = (clock.now - processor.streamWallStart) / .seconds(1)
    let tps: Double? = {
      guard let c = u.outputTokens, c > 0 else { return nil }
      return Double(c) / max(0.001, genSec)
    }()
    logger.debug(
      "agent.stream.end.codex",
      metadata: [
        "chunks": "\(processor.decodedChunkCount)",
        "prompt_tokens": "\(u.inputTokens.map(String.init(describing:)) ?? "nil")",
        "completion_tokens": "\(u.outputTokens.map(String.init(describing:)) ?? "nil")",
        "tps": "\(tps.map { String(format: "%.1f", $0) } ?? "nil")",
      ])
    let usage = ScribeUsage(
      promptTokens: u.inputTokens,
      completionTokens: u.outputTokens,
      totalTokens: u.totalTokens,
      reasoningTokens: u.outputTokensDetails?.reasoningTokens,
      cachedPromptTokens: u.inputTokensDetails?.cachedTokens
    )
    emit(.lifecycle(.usage(usage, tokensPerSecond: tps)))
  }

  if toolInvocations.isEmpty {
    if processor.isIncomplete {
      logger.warning(
        "agent.assistant.incomplete.codex",
        metadata: [
          "reason": "\(processor.incompleteReason ?? "unknown")",
          "answer_chars": "\(turn.text.count)",
        ])
      return CodexRoundResult(
        assistantMessage: assistantMessage,
        kind: .incomplete(reason: processor.incompleteReason))
    }
    logger.info("agent.assistant.final.codex", metadata: ["answer_chars": "\(turn.text.count)"])
    return CodexRoundResult(assistantMessage: assistantMessage, kind: .completed)
  }

  if processor.isIncomplete {
    logger.warning(
      "agent.assistant.incomplete.codex",
      metadata: [
        "reason": "\(processor.incompleteReason ?? "unknown")",
        "tool_count": "\(toolInvocations.count)",
      ])
  }

  return CodexRoundResult(assistantMessage: assistantMessage, kind: .toolCalls(toolInvocations))
}

// MARK: - Message Conversion

private struct CodexRequestMetrics {
  var textChars = 0
  var imageCount = 0
  var imageURIChars = 0
  var toolCallCount = 0
  var toolOutputChars = 0
}

private func codexRequestMetrics(
  _ messages: [ScribeLLM.Components.Schemas.ChatMessage]
) -> CodexRequestMetrics {
  var metrics = CodexRequestMetrics()
  for message in messages {
    if let content = message.content {
      switch content {
      case .case1(let text):
        metrics.textChars += text.count
        if message.role == .tool { metrics.toolOutputChars += text.count }
      case .case2(let parts):
        for part in parts {
          switch part {
          case .text(let text):
            metrics.textChars += text.text.count
          case .imageUrl(let image):
            metrics.imageCount += 1
            metrics.imageURIChars += image.imageUrl.url.count
          }
        }
      }
    }
    metrics.toolCallCount += message.toolCalls?.count ?? 0
  }
  return metrics
}

func codexAttachmentMessage(
  _ attachment: ToolAttachment
) -> ScribeLLM.Components.Schemas.ChatMessage {
  let label = (attachment.sourcePath ?? attachment.filename).map { "\($0):" } ?? "Attached media:"
  return ScribeMessage(
    role: .user,
    contentParts: [
      .text(label),
      .image(url: attachment.dataUri, detail: nil),
    ]
  ).toChatMessage()
}

/// Convert standard ChatMessage array to Codex input items.
func convertChatMessagesToCodexInput(
  _ messages: [ScribeLLM.Components.Schemas.ChatMessage]
) -> [ScribeLLMCodex.Components.Schemas.CodexInputItem]? {
  var items: [ScribeLLMCodex.Components.Schemas.CodexInputItem] = []
  for msg in messages {
    switch msg.role {
    case .system:
      let content = msgContentString(msg) ?? ""
      items.append(
        .system(
          ScribeLLMCodex.Components.Schemas.CodexSystemMessage(
            role: .system, content: content
          )))

    case .user:
      if let content = msg.content {
        switch content {
        case .case1(let text):
          items.append(
            .user(
              ScribeLLMCodex.Components.Schemas.CodexUserMessage(
                role: .user,
                content: .case1(text)
              )))
        case .case2(let parts):
          let codexParts = parts.map(convertChatContentPartToCodexInputContent)
          items.append(
            .user(
              ScribeLLMCodex.Components.Schemas.CodexUserMessage(
                role: .user,
                content: .case2(codexParts)
              )))
        }
      }

    case .assistant:
      if let text = msgContentString(msg), !text.isEmpty {
        items.append(
          .assistant(
            ScribeLLMCodex.Components.Schemas.CodexAssistantMessage(
              role: .assistant,
              content: .case1(text),
              id: nil,
              status: nil,
              phase: nil
            )))
      }
      if let toolCalls = msg.toolCalls {
        for tc in toolCalls {
          let identifiers = CodexToolCallIdentifiers(encoded: tc.id ?? "")
          items.append(
            .functionCall(
              ScribeLLMCodex.Components.Schemas.CodexFunctionCall(
                _type: .functionCall,
                id: identifiers.itemID,
                callId: identifiers.callID,
                name: tc.function?.name ?? "",
                arguments: tc.function?.arguments ?? "{}"
              )))
        }
      }

    case .tool:
      if let resultText = msgContentString(msg), let callId = msg.toolCallId {
        let shortCallId = CodexToolCallIdentifiers(encoded: callId).callID
        items.append(
          .functionCallOutput(
            ScribeLLMCodex.Components.Schemas.CodexFunctionCallOutput(
              _type: .functionCallOutput,
              callId: shortCallId,
              output: .case1(resultText)
            )))
      }
    }
  }
  return items.isEmpty ? nil : items
}

private func msgContentString(_ msg: ScribeLLM.Components.Schemas.ChatMessage) -> String? {
  guard let content = msg.content else { return nil }
  switch content {
  case .case1(let str): return str
  default: return nil
  }
}

func convertChatContentPartToCodexInputContent(
  _ part: ScribeLLM.Components.Schemas.ChatContentPart
) -> ScribeLLMCodex.Components.Schemas.CodexInputContent {
  switch part {
  case .text(let textPart):
    return .inputText(
      ScribeLLMCodex.Components.Schemas.CodexInputText(
        _type: .inputText,
        text: textPart.text
      ))
  case .imageUrl(let imagePart):
    return .inputImage(
      ScribeLLMCodex.Components.Schemas.CodexInputImage(
        _type: .inputImage,
        imageUrl: imagePart.imageUrl.url,
        detail: imagePart.imageUrl.detail.map { detail in
          switch detail {
          case .auto: return .auto
          case .low: return .low
          case .high: return .high
          }
        }
      ))
  }
}

private func convertToCodexTools(
  _ chatTools: [ScribeLLM.Components.Schemas.ChatTool]
) -> [ScribeLLMCodex.Components.Schemas.CodexTool]? {
  guard !chatTools.isEmpty else { return nil }
  return chatTools.map { ct in
    var codexParams = ScribeLLMCodex.Components.Schemas.CodexTool.ParametersPayload()
    codexParams.additionalProperties = ct.function.parameters.additionalProperties
    return ScribeLLMCodex.Components.Schemas.CodexTool(
      _type: .function,
      name: ct.function.name,
      description: ct.function.description,
      parameters: codexParams,
      strict: false,
      deferLoading: nil
    )
  }
}
