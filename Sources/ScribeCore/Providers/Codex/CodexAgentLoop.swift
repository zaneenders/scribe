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
    if parts.count == 2 {
      callID = String(parts[0])
      itemID = String(parts[1])
    } else {
      // Foreign or legacy ID, e.g. left in the history by a non-Codex provider
      // before a mid-session model switch. The ChatGPT backend requires item IDs
      // beginning with "fc" and call IDs beginning with "call_"; derive both
      // deterministically so the function_call and its function_call_output,
      // which share this encoded ID, stay paired.
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
    // Deterministic fallback (FNV-1a) so a call and its output still pair up.
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in id.utf8 {
      hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
    }
    return String(hash, radix: 16)
  }
}

// MARK: - Codex Agent Loop

/// Configuration for the Codex agent loop.
struct CodexAgentLoopConfig: Sendable, AgentLoopConfigFields {
  let model: String
  let client: ScribeLLMCodex.Client
  let toolExecutor: any ToolExecutor
  let chatTools: [ScribeLLM.Components.Schemas.ChatTool]
  let maxToolRounds: Int
  let workingDirectory: FilePath
  let reasoningEnabled: Bool?
  let reasoningEffort: String?
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
    reasoningEffort: String? = nil,
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
    self.reasoningEffort = reasoningEffort
    self.hooks = hooks
    self.contextWindow = contextWindow
  }
}

/// Runs the agent loop against the Codex (ChatGPT subscription) API. The orchestration
/// lives in `runAgentLoopCore`; this entry point only supplies the provider-specific
/// HTTP round.
func runCodexAgentLoop(
  promptMessages: [ScribeLLM.Components.Schemas.ChatMessage],
  context: AgentContext,
  config: CodexAgentLoopConfig,
  emit: @escaping @Sendable (AgentEvent) -> Void,
  logger: Logger,
  abortObserver: some AbortObserver
) async throws -> (messages: [ScribeLLM.Components.Schemas.ChatMessage], termination: TurnOutcome) {
  try await runAgentLoopCore(
    promptMessages: promptMessages,
    context: context,
    config: config,
    logTag: ".codex",
    emit: emit,
    logger: logger,
    abortObserver: abortObserver
  ) { contextMessages, round in
    try await runSingleCodexRound(
      contextMessages: contextMessages,
      config: config,
      emit: emit,
      logger: logger,
      round: round,
      abortObserver: abortObserver
    )
  }
}

// MARK: - Single Round

private func runSingleCodexRound(
  contextMessages: [ScribeLLM.Components.Schemas.ChatMessage],
  config: CodexAgentLoopConfig,
  emit: @escaping @Sendable (AgentEvent) -> Void,
  logger: Logger,
  round: Int,
  abortObserver: some AbortObserver
) async throws -> RoundResult {
  let clock = ContinuousClock()

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
        r.effort =
          config.reasoningEffort
          .flatMap { ScribeLLMCodex.Components.Schemas.CodexReasoning.EffortPayload(rawValue: $0) }
          ?? .medium
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
      return RoundResult(
        assistantMessage: assistantMessage,
        kind: .incomplete(reason: processor.incompleteReason))
    }
    logger.info("agent.assistant.final.codex", metadata: ["answer_chars": "\(turn.text.count)"])
    return RoundResult(assistantMessage: assistantMessage, kind: .completed)
  }

  if processor.isIncomplete {
    logger.warning(
      "agent.assistant.incomplete.codex",
      metadata: [
        "reason": "\(processor.incompleteReason ?? "unknown")",
        "tool_count": "\(toolInvocations.count)",
      ])
  }

  return RoundResult(assistantMessage: assistantMessage, kind: .toolCalls(toolInvocations))
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
