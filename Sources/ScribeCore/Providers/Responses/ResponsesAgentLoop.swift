import Foundation
import Logging
import OpenAPIRuntime
import ScribeCodexAuth
import ScribeLLM
import ScribeLLMResponses
import SystemPackage

struct ResponsesToolCallIdentifiers: Equatable {
  private static let separator: Character = "|"

  let callID: String
  let itemID: String

  init(callID: String, itemID: String) {
    self.callID = callID
    self.itemID = itemID
  }

  init(encoded: String) {
    let parts = encoded.split(separator: Self.separator, maxSplits: 1, omittingEmptySubsequences: false)
    if parts.count == 2 {
      callID = String(parts[0])
      itemID = String(parts[1])
    } else {
      let cleaned = Self.sanitize(encoded)
      callID = cleaned.hasPrefix("call_") ? cleaned : "call_" + cleaned
      itemID = cleaned.hasPrefix("fc_") ? cleaned : "fc_" + cleaned
    }
  }

  var encoded: String {
    "\(callID)\(Self.separator)\(itemID)"
  }

  private static func sanitize(_ id: String) -> String {
    let cleaned = id.filter { char in
      char == "_" || char == "-" || (char.isASCII && (char.isLetter || char.isNumber))
    }
    if !cleaned.isEmpty { return cleaned }
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in id.utf8 {
      hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
    }
    return String(hash, radix: 16)
  }
}

struct ResponsesAgentLoopConfig: Sendable, AgentLoopConfigFields {
  let model: String
  let client: ScribeLLMResponses.Client
  let toolExecutor: any ToolExecutor
  let chatTools: [ScribeLLM.Components.Schemas.ChatTool]
  let maxToolRounds: Int
  let workingDirectory: FilePath
  let reasoningEnabled: Bool?
  let reasoningEffort: String?
  let serviceTier: String?
  let usesCodexBackend: Bool
  let temperature: Double?
  let hooks: AgentLoopHooks
  let contextWindow: Int
  let retryPolicy: RetryPolicy

  init(
    model: String,
    client: ScribeLLMResponses.Client,
    toolExecutor: any ToolExecutor,
    chatTools: [ScribeLLM.Components.Schemas.ChatTool],
    maxToolRounds: Int,
    workingDirectory: FilePath,
    reasoningEnabled: Bool?,
    reasoningEffort: String? = nil,
    serviceTier: String? = nil,
    usesCodexBackend: Bool = true,
    temperature: Double? = nil,
    hooks: AgentLoopHooks,
    contextWindow: Int = 0,
    retryPolicy: RetryPolicy = .default
  ) {
    self.model = model
    self.client = client
    self.toolExecutor = toolExecutor
    self.chatTools = chatTools
    self.maxToolRounds = maxToolRounds
    self.workingDirectory = workingDirectory
    self.reasoningEnabled = reasoningEnabled
    self.reasoningEffort = reasoningEffort
    self.serviceTier = serviceTier
    self.usesCodexBackend = usesCodexBackend
    self.temperature = temperature
    self.hooks = hooks
    self.contextWindow = contextWindow
    self.retryPolicy = retryPolicy
  }
}

func runResponsesAgentLoop(
  promptMessages: [ScribeLLM.Components.Schemas.ChatMessage],
  context: AgentContext,
  config: ResponsesAgentLoopConfig,
  emit: @escaping @Sendable (AgentEvent) -> Void,
  logger: Logger,
  abortObserver: some AbortObserver
) async throws -> (messages: [ScribeLLM.Components.Schemas.ChatMessage], termination: TurnOutcome) {
  try await runAgentLoopCore(
    promptMessages: promptMessages,
    context: context,
    config: config,
    logTag: ".responses",
    emit: emit,
    logger: logger,
    abortObserver: abortObserver
  ) { contextMessages, round, roundEmit in
    try await runSingleResponsesRound(
      contextMessages: contextMessages,
      config: config,
      emit: roundEmit,
      logger: logger,
      round: round,
      abortObserver: abortObserver
    )
  }
}

private func runSingleResponsesRound(
  contextMessages: [ScribeLLM.Components.Schemas.ChatMessage],
  config: ResponsesAgentLoopConfig,
  emit: @escaping @Sendable (AgentEvent) -> Void,
  logger: Logger,
  round: Int,
  abortObserver: some AbortObserver
) async throws -> RoundResult {
  let clock = ContinuousClock()

  emit(.boundary(.messageStart(role: .assistant, round: round)))

  let input = convertChatMessagesToResponsesInput(contextMessages)
  let responsesTools = convertToResponsesTools(config.chatTools)

  let requestBody = ScribeLLMResponses.Components.Schemas.CreateResponseRequest(
    model: config.model,
    store: false,
    stream: true,
    instructions: nil,
    previousResponseId: nil,
    input: input,
    tools: responsesTools,
    toolChoice: .auto,
    parallelToolCalls: true,
    temperature: config.temperature.map(Float.init),
    reasoning: config.reasoningEnabled == true
      ? {
        var r = ScribeLLMResponses.Components.Schemas.ResponsesReasoning()
        r.effort =
          config.reasoningEffort
          .flatMap { ScribeLLMResponses.Components.Schemas.ResponsesReasoning.EffortPayload(rawValue: $0) }
          ?? .medium
        r.summary = .auto
        return r
      }()
      : nil,
    serviceTier: config.usesCodexBackend
      ? config.serviceTier.flatMap(
        ScribeLLMResponses.Components.Schemas.CreateResponseRequest.ServiceTierPayload.init(rawValue:))
      : nil,
    text: nil,
    include: config.usesCodexBackend ? ["reasoning.encrypted_content"] : nil,
    promptCacheKey: nil
  )

  let requestMetrics = responsesRequestMetrics(contextMessages)
  let httpStart = clock.now
  logger.info(
    "agent.http.request.responses",
    metadata: [
      "model": "\(config.model)",
      "round": "\(round)",
      "messages": "\(contextMessages.count)",
      "input_items": "\(input?.count ?? 0)",
      "tools": "\(responsesTools?.count ?? 0)",
      "text_chars": "\(requestMetrics.textChars)",
      "image_count": "\(requestMetrics.imageCount)",
      "image_uri_chars": "\(requestMetrics.imageURIChars)",
      "tool_call_count": "\(requestMetrics.toolCallCount)",
      "tool_output_chars": "\(requestMetrics.toolOutputChars)",
    ])

  let response: ScribeLLMResponses.Operations.CreateResponse.Output
  do {
    response = try await config.client.createResponse(body: .json(requestBody))
  } catch let error as ClientError where error.underlyingError is CodexOAuthError {
    throw ScribeError.generic(String(describing: error.underlyingError))
  }

  let httpBody: HTTPBody
  switch response {
  case .ok(let ok):
    logger.debug(
      "agent.http.response.responses",
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
    logger.warning("agent.http.response.responses", metadata: ["status": "\(code)"])
    throw ScribeError.responsesHTTPError(statusCode: code, detail: detail)
  }

  var turn = ResponsesAssistantTurn()
  var processor = ResponsesStreamProcessor(
    onEvent: emit,
    logger: logger,
    abortObserver: abortObserver,
    streamWallStart: clock.now
  )
  do {
    try await processor.process(httpBody: httpBody, httpStart: httpStart, turn: &turn)
  } catch let error as ScribeError {
    let hasPartialMessage = !turn.text.isEmpty || !turn.reasoningText.isEmpty
    guard hasPartialMessage else { throw error }
    return partialRoundResult(
      text: turn.text,
      reasoning: turn.reasoningText,
      error: error,
      round: round,
      emit: emit)
  } catch is AgentTurnInterruptedError {
    throw AgentTurnInterruptedError()
  } catch is CancellationError {
    throw CancellationError()
  } catch {
    let hasPartialMessage = !turn.text.isEmpty || !turn.reasoningText.isEmpty
    guard hasPartialMessage else { throw error }
    return partialRoundResult(
      text: turn.text,
      reasoning: turn.reasoningText,
      error: error,
      round: round,
      emit: emit)
  }

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
    let genSec = (clock.now - processor.streamWallStart) / .seconds(1)
    let tps: Double? = {
      guard let c = u.outputTokens, c > 0 else { return nil }
      return Double(c) / max(0.001, genSec)
    }()
    logger.debug(
      "agent.stream.end.responses",
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
        "agent.assistant.incomplete.responses",
        metadata: [
          "reason": "\(processor.incompleteReason ?? "unknown")",
          "answer_chars": "\(turn.text.count)",
        ])
      return RoundResult(
        assistantMessage: assistantMessage,
        kind: .incomplete(reason: processor.incompleteReason))
    }
    logger.info("agent.assistant.final.responses", metadata: ["answer_chars": "\(turn.text.count)"])
    return RoundResult(assistantMessage: assistantMessage, kind: .completed)
  }

  if processor.isIncomplete {
    logger.warning(
      "agent.assistant.incomplete.responses",
      metadata: [
        "reason": "\(processor.incompleteReason ?? "unknown")",
        "tool_count": "\(toolInvocations.count)",
      ])
  }

  return RoundResult(assistantMessage: assistantMessage, kind: .toolCalls(toolInvocations))
}

private struct ResponsesRequestMetrics {
  var textChars = 0
  var imageCount = 0
  var imageURIChars = 0
  var toolCallCount = 0
  var toolOutputChars = 0
}

private func responsesRequestMetrics(
  _ messages: [ScribeLLM.Components.Schemas.ChatMessage]
) -> ResponsesRequestMetrics {
  var metrics = ResponsesRequestMetrics()
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

func convertChatMessagesToResponsesInput(
  _ messages: [ScribeLLM.Components.Schemas.ChatMessage]
) -> [ScribeLLMResponses.Components.Schemas.ResponsesInputItem]? {
  var items: [ScribeLLMResponses.Components.Schemas.ResponsesInputItem] = []
  for msg in messages {
    switch msg.role {
    case .system:
      let content = msgContentString(msg) ?? ""
      items.append(
        .system(
          ScribeLLMResponses.Components.Schemas.ResponsesSystemMessage(
            role: .system, content: content
          )))

    case .user:
      if let content = msg.content {
        switch content {
        case .case1(let text):
          items.append(
            .user(
              ScribeLLMResponses.Components.Schemas.ResponsesUserMessage(
                role: .user,
                content: .case1(text)
              )))
        case .case2(let parts):
          let responsesParts = parts.map(convertChatContentPartToResponsesInputContent)
          items.append(
            .user(
              ScribeLLMResponses.Components.Schemas.ResponsesUserMessage(
                role: .user,
                content: .case2(responsesParts)
              )))
        }
      }

    case .assistant:
      if let text = msgContentString(msg), !text.isEmpty {
        items.append(
          .assistant(
            ScribeLLMResponses.Components.Schemas.ResponsesAssistantMessage(
              role: .assistant,
              content: .case1(text),
              id: nil,
              status: nil,
              phase: nil
            )))
      }
      if let toolCalls = msg.toolCalls {
        for tc in toolCalls {
          let identifiers = ResponsesToolCallIdentifiers(encoded: tc.id ?? "")
          items.append(
            .functionCall(
              ScribeLLMResponses.Components.Schemas.ResponsesFunctionCall(
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
        let shortCallId = ResponsesToolCallIdentifiers(encoded: callId).callID
        items.append(
          .functionCallOutput(
            ScribeLLMResponses.Components.Schemas.ResponsesFunctionCallOutput(
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

func convertChatContentPartToResponsesInputContent(
  _ part: ScribeLLM.Components.Schemas.ChatContentPart
) -> ScribeLLMResponses.Components.Schemas.ResponsesInputContent {
  switch part {
  case .text(let textPart):
    return .inputText(
      ScribeLLMResponses.Components.Schemas.ResponsesInputText(
        _type: .inputText,
        text: textPart.text
      ))
  case .imageUrl(let imagePart):
    return .inputImage(
      ScribeLLMResponses.Components.Schemas.ResponsesInputImage(
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

private func convertToResponsesTools(
  _ chatTools: [ScribeLLM.Components.Schemas.ChatTool]
) -> [ScribeLLMResponses.Components.Schemas.ResponsesTool]? {
  guard !chatTools.isEmpty else { return nil }
  return chatTools.map { ct in
    var responsesParams = ScribeLLMResponses.Components.Schemas.ResponsesTool.ParametersPayload()
    responsesParams.additionalProperties = ct.function.parameters.additionalProperties
    return ScribeLLMResponses.Components.Schemas.ResponsesTool(
      _type: .function,
      name: ct.function.name,
      description: ct.function.description,
      parameters: responsesParams,
      strict: false,
      deferLoading: nil
    )
  }
}
