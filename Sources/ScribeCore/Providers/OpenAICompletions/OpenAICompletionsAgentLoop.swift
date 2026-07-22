import Foundation
import Logging
import OpenAPIRuntime
import ScribeLLM
import SystemPackage

/// Configuration for the OpenAI-compatible agent loop.
struct AgentLoopConfig: Sendable, AgentLoopConfigFields {
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
  let contextWindow: Int
  let retryPolicy: RetryPolicy

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
    maxCompletionTokens: Int? = nil,
    contextWindow: Int = 0,
    retryPolicy: RetryPolicy = .default
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
    self.contextWindow = contextWindow
    self.retryPolicy = retryPolicy
  }
}

/// Runs the agent loop against an OpenAI-compatible chat-completions API. The
/// orchestration lives in `runAgentLoopCore`; this entry point only supplies the
/// provider-specific HTTP round.
func runAgentLoop(
  promptMessages: [Components.Schemas.ChatMessage],
  context: AgentContext,
  config: AgentLoopConfig,
  emit: @escaping @Sendable (AgentEvent) -> Void,
  logger: Logger,
  abortObserver: some AbortObserver
) async throws -> (messages: [Components.Schemas.ChatMessage], termination: TurnOutcome) {
  try await runAgentLoopCore(
    promptMessages: promptMessages,
    context: context,
    config: config,
    logTag: "",
    emit: emit,
    logger: logger,
    abortObserver: abortObserver
  ) { contextMessages, round, roundEmit in
    try await runSingleRound(
      contextMessages: contextMessages,
      config: config,
      emit: roundEmit,
      logger: logger,
      round: round,
      abortObserver: abortObserver
    )
  }
}

// MARK: - Single Round

private func runSingleRound(
  contextMessages: [Components.Schemas.ChatMessage],
  config: AgentLoopConfig,
  emit: @escaping @Sendable (AgentEvent) -> Void,
  logger: Logger,
  round: Int,
  abortObserver: some AbortObserver
) async throws -> RoundResult {
  let clock = ContinuousClock()

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
        return
          " Check your API key matches api.baseUrl: Kimi Code keys require https://api.kimi.com/coding; Moonshot platform keys require https://api.moonshot.ai."
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
    // Usage completion tokens can include hidden reasoning, so measure from the
    // start of the response stream rather than the first visible content delta.
    let genSec = (clock.now - processor.streamWallStart) / .seconds(1)
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
  let isIncomplete =
    normalizedFinishReason.map { reason in
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
