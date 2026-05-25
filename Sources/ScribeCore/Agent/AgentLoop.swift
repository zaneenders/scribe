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
}

private struct RoundSettings: Sendable {
  var model: String
  var temperature: Double
  var reasoningEnabled: Bool?

  init(config: AgentLoopConfig) {
    model = config.model
    temperature = config.temperature
    reasoningEnabled = config.reasoningEnabled
  }

  mutating func apply(_ overrides: NextTurnOverrides) {
    if let model = overrides.model { self.model = model }
    if let temperature = overrides.temperature { self.temperature = temperature }
    if let reasoningEnabled = overrides.reasoningEnabled { self.reasoningEnabled = reasoningEnabled }
  }
}

enum LoopTermination: Sendable {
  case completed
  case interrupted
  case toolRoundLimit(rounds: Int)
}

private func turnOutcome(from termination: LoopTermination) -> TurnOutcome {
  switch termination {
  case .completed: return .completed
  case .interrupted: return .interrupted
  case .toolRoundLimit(let rounds): return .toolRoundLimit(rounds: rounds)
  }
}

func runAgentLoop(
  promptMessages: [Components.Schemas.ChatMessage],
  context: AgentContext,
  config: AgentLoopConfig,
  emit: @escaping @Sendable (AgentEvent) -> Void,
  logger: Logger,
  abortObserver: some AbortObserver
) async throws -> (messages: [Components.Schemas.ChatMessage], termination: LoopTermination) {
  var currentContext = context
  var newMessages: [Components.Schemas.ChatMessage] = []
  var roundSettings = RoundSettings(config: config)
  var termination: LoopTermination = .completed

  emit(.boundary(.agentStart))

  defer {
    emit(.boundary(.agentEnd(turnOutcome(from: termination))))
  }

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
      termination = .interrupted
      return (newMessages, termination)
    }

    emit(.boundary(.turnStart(round: round)))

    let overrides = await config.hooks.prepareNextTurn(round, currentContext.messages)
    roundSettings.apply(overrides)
    currentContext.messages = await config.hooks.transformContext(currentContext.messages)

    let messagesCountBeforeRound = currentContext.messages.count
    let roundResult: RoundOutcome
    do {

      let outcome = try await abortObserver.race {
        [currentContext, config, emit, logger, round, roundSettings, abortObserver] in
        var localCtx = currentContext
        let result = try await runSingleRound(
          context: &localCtx,
          config: config,
          roundSettings: roundSettings,
          emit: emit,
          logger: logger,
          clock: clock,
          round: round,
          abortObserver: abortObserver
        )
        return RoundExecutionResult(context: localCtx, outcome: result)
      }
      currentContext = outcome.context
      roundResult = outcome.outcome
    } catch is AgentTurnInterruptedError {
      logger.notice(
        "agent.abort",
        metadata: [
          "where": "mid-stream", "round": "\(round)",
        ])
      emit(.boundary(.turnEnd(round: round, outcome: .interrupted)))
      termination = .interrupted
      return (newMessages, termination)
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
    }

    let roundMessages = Array(currentContext.messages[messagesCountBeforeRound...])
    newMessages.append(contentsOf: roundMessages)

    if abortObserver.isAborted() {
      logger.debug("agent.abort", metadata: ["where": "post-stream-pre-tools", "round": "\(round)"])

      currentContext.messages.removeSubrange(messagesCountBeforeRound..<currentContext.messages.endIndex)
      newMessages.removeSubrange(newMessages.count - roundMessages.count..<newMessages.count)
      emit(.boundary(.turnEnd(round: round, outcome: .interrupted)))
      termination = .interrupted
      return (newMessages, termination)
    }

    switch roundResult {
    case .completed:
      emit(.boundary(.turnEnd(round: round, outcome: .completed)))
      if await config.hooks.shouldStopAfterTurn(round) {
        termination = .completed
        return (newMessages, termination)
      }
      termination = .completed
      return (newMessages, termination)

    case .toolCalls(let invocations):
      emit(.boundary(.turnEnd(round: round, outcome: .toolCalls(count: invocations.count))))
      if round >= config.maxToolRounds {
        logger.notice(
          "agent.turn.tool-round-limit",
          metadata: ["max": "\(config.maxToolRounds)"])
        currentContext.messages.removeSubrange(messagesCountBeforeRound..<currentContext.messages.endIndex)
        newMessages.removeSubrange(newMessages.count - roundMessages.count..<newMessages.count)
        termination = .toolRoundLimit(rounds: config.maxToolRounds)
        return (newMessages, termination)
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
            metadata: [
              "where": "pre-tool", "tool": "\(inv.name)", "round": "\(round)",
            ])
          currentContext.messages.removeSubrange(messagesCountBeforeRound..<currentContext.messages.endIndex)
          newMessages.removeSubrange(newMessages.count - roundMessages.count..<newMessages.count)
          termination = .interrupted
          return (newMessages, termination)
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
            currentContext.messages.removeSubrange(messagesCountBeforeRound..<currentContext.messages.endIndex)
            newMessages.removeSubrange(newMessages.count - roundMessages.count..<newMessages.count)
            termination = .interrupted
            return (newMessages, termination)
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
        let toolMsg = Components.Schemas.ChatMessage(
          role: .tool, content: .case1(finalResult.text), name: nil, toolCalls: nil, toolCallId: resolvedInv.id)
        currentContext.messages.append(toolMsg)
        newMessages.append(toolMsg)
        emit(.boundary(.messageEnd(role: .tool, round: round)))

        for attachment in finalResult.attachments {
          let b64chars = attachment.base64.count
          logger.info(
            "agent.tool.attachment.inject",
            metadata: [
              "round": "\(round)",
              "tool": "\(resolvedInv.name)",
              "mime_type": "\(attachment.mimeType)",
              "base64_chars": "\(b64chars)",
              "source_path": "\(attachment.sourcePath ?? "nil")",
            ])
          let parts: [ScribeContentPart] = [
            .text((attachment.sourcePath ?? attachment.filename).map { "\($0):" } ?? "Attached media:"),
            .image(url: attachment.dataUri, detail: nil),
          ]
          emit(.boundary(.messageStart(role: .user, round: round)))
          let imageMsg = ScribeMessage(role: .user, contentParts: parts).toChatMessage()
          currentContext.messages.append(imageMsg)
          newMessages.append(imageMsg)
          emit(.boundary(.messageEnd(role: .user, round: round)))
        }

        if afterDecision.terminate {
          termination = .completed
          return (newMessages, termination)
        }
      }
    }
  }
}

private enum RoundOutcome: Sendable, Equatable {
  case completed
  case toolCalls([ToolInvocation])
}

private struct RoundExecutionResult: Sendable {
  let context: AgentContext
  let outcome: RoundOutcome
}

private func runSingleRound(
  context: inout AgentContext,
  config: AgentLoopConfig,
  roundSettings: RoundSettings,
  emit: @escaping @Sendable (AgentEvent) -> Void,
  logger: Logger,
  clock: ContinuousClock,
  round: Int,
  abortObserver: some AbortObserver
) async throws -> RoundOutcome {

  emit(.boundary(.messageStart(role: .assistant, round: round)))

  let requestBody = Components.Schemas.CreateChatCompletionRequest(
    model: roundSettings.model,
    messages: context.messages,
    stream: true,
    temperature: Float(roundSettings.temperature),
    maxTokens: nil,
    tools: config.chatTools,
    toolChoice: nil,
    streamOptions: .init(includeUsage: true),
    reasoning: roundSettings.reasoningEnabled == nil
      ? nil : Components.Schemas.ChatCompletionReasoning(enabled: roundSettings.reasoningEnabled)
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
  context.messages.append(assistantMessage)
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
    return .completed
  }

  return .toolCalls(toolInvocations)
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
