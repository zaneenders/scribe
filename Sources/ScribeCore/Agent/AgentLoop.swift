import SystemPackage
import Foundation
import Logging
import OpenAPIRuntime
import ScribeLLM

// MARK: - AgentContext / AgentLoopConfig

/// Immutable snapshot of agent state taken before a run starts.
///
/// The system prompt is no longer carried separately — callers are expected
/// to bake it into the head of `messages` (the agent's public constructors
/// do this automatically for embedders that don't pre-include one).
struct AgentContext: Sendable {
  var messages: [Components.Schemas.ChatMessage]
}

/// Bundled configuration for a single agent run — everything derived from
/// agent setup + per-call options.
struct AgentLoopConfig: Sendable {
  let model: String
  let client: Client
  /// Pluggable execution backend. The default ``ToolRegistry`` runs tools
  /// in-process; embedders can swap in an approval / sandbox / forwarding
  /// executor without subclassing.
  let toolExecutor: any ToolExecutor
  /// Tool schemas advertised to the model.  Derived from the same
  /// `[any ScribeTool]` that backs the default ``ToolRegistry`` so
  /// schema and execution surface stay in sync.  When a custom
  /// ``ToolExecutor`` is supplied, schemas are derived from the `tools`
  /// parameter of ``ScribeAgent`` and the caller is responsible for
  /// consistency (mismatches are surfaced as recoverable JSON errors).
  let chatTools: [Components.Schemas.ChatTool]
  let temperature: Double
  let maxToolRounds: Int
  let workingDirectory: FilePath
  let reasoningEnabled: Bool?
}

/// Why the agent loop stopped.
enum LoopTermination: Sendable {
  case completed
  case interrupted
  case toolRoundLimit(rounds: Int)
}

// MARK: - runAgentLoop

/// Execute the agent loop for a set of prompt messages.
///
/// Pure — no `self`, no side effects except through `emit`. The caller
/// owns `context` (snapshot) and `config` (derived from agent + per-call
/// options). Returns the new messages and the reason the loop stopped.
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

  // Append prompt messages to context
  for msg in promptMessages {
    currentContext.messages.append(msg)
    newMessages.append(msg)
  }

  let clock = ContinuousClock()
  var round = 0
  var attemptedRecovery = false

  while true {
    round += 1
    if abortObserver.isAborted() {
      logger.debug("agent.abort", metadata: ["where": "before-http", "round": "\(round)"])
      return (newMessages, .interrupted)
    }

    let messagesCountBeforeRound = currentContext.messages.count
    let roundResult: RoundOutcome
    do {
      roundResult = try await runSingleRound(
        context: &currentContext,
        config: config,
        emit: emit,
        logger: logger,
        clock: clock,
        round: round,
        abortObserver: abortObserver
      )
    } catch is AgentTurnInterruptedError {
      logger.notice(
        "agent.abort",
        metadata: [
          "where": "mid-stream", "round": "\(round)",
        ])
      return (newMessages, .interrupted)
    } catch let scribeError as ScribeError where !attemptedRecovery && isContextLengthError(scribeError) {
      // Attachment-overflow recovery: the previous round's tool likely
      // injected a too-large synthetic-attachment user message. Drop the
      // attachments, replace the tool result with an error so the model
      // sees the failure, and retry once.
      guard case .apiHTTPError(_, let detail, _) = scribeError else {
        throw scribeError
      }
      guard
        let reason = rollbackAttachmentOverflow(
          messages: &currentContext.messages,
          newMessages: &newMessages,
          providerDetail: detail)
      else {
        // No recoverable shape at the tail — propagate the original error.
        throw scribeError
      }
      attemptedRecovery = true
      logger.notice("agent.recover", metadata: ["reason": "\(reason)"])
      emit(.lifecycle(.recovered(reason: reason)))
      continue
    }

    // Collect new messages from this round
    let roundMessages = Array(currentContext.messages[messagesCountBeforeRound...])
    newMessages.append(contentsOf: roundMessages)

    if abortObserver.isAborted() {
      logger.debug("agent.abort", metadata: ["where": "post-stream-pre-tools", "round": "\(round)"])
      // Remove uncommitted round messages
      currentContext.messages.removeSubrange(messagesCountBeforeRound..<currentContext.messages.endIndex)
      newMessages.removeSubrange(newMessages.count - roundMessages.count..<newMessages.count)
      return (newMessages, .interrupted)
    }

    switch roundResult {
    case .completed:
      return (newMessages, .completed)

    case .toolCalls(let invocations):
      if round >= config.maxToolRounds {
        logger.notice(
          "agent.turn.tool-round-limit",
          metadata: ["max": "\(config.maxToolRounds)"])
        currentContext.messages.removeSubrange(messagesCountBeforeRound..<currentContext.messages.endIndex)
        newMessages.removeSubrange(newMessages.count - roundMessages.count..<newMessages.count)
        return (newMessages, .toolRoundLimit(rounds: config.maxToolRounds))
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
          return (newMessages, .interrupted)
        }
        let result: ToolResult
        do {
          result = try await config.toolExecutor.execute(
            inv,
            workingDirectory: config.workingDirectory,
            logger: logger,
            abort: abortObserver)
        } catch is AgentTurnInterruptedError {
          currentContext.messages.removeSubrange(messagesCountBeforeRound..<currentContext.messages.endIndex)
          newMessages.removeSubrange(newMessages.count - roundMessages.count..<newMessages.count)
          return (newMessages, .interrupted)
        } catch let ScribeError.toolUnknown(name) {
          logger.warning("agent.tool.unknown", metadata: ["tool": "\(name)", "round": "\(round)"])
          result = ToolResult.text(ToolRegistry.jsonError("unknown tool \(name)"))
        } catch {
          // Defensive: a custom ToolExecutor may throw arbitrary errors.
          // Surface them to the model as a JSON-encoded tool failure so the
          // assistant can self-correct, rather than aborting the turn.
          logger.warning(
            "agent.tool.executor.error",
            metadata: [
              "tool": "\(inv.name)", "round": "\(round)",
              "err": "\(String(describing: error).replacingOccurrences(of: "\"", with: "\\\""))",
            ])
          result = ToolResult.text(ToolRegistry.jsonError(String(describing: error)))
        }
        emit(.tool(.invocation(name: inv.name, arguments: inv.arguments, output: result.text)))
        for warning in result.warnings {
          emit(.tool(.warning(warning)))
        }
        let toolMsg = Components.Schemas.ChatMessage(
          role: .tool, content: .case1(result.text), name: nil, toolCalls: nil, toolCallId: inv.id)
        currentContext.messages.append(toolMsg)
        newMessages.append(toolMsg)

        // If the tool returned attachments (images, PDFs, etc.), inject a
        // follow-up user message so the model can view them on the next
        // turn.  OpenAI-compatible APIs only accept string content in
        // tool results, so media must flow through synthetic user messages.
        for attachment in result.attachments {
          let b64chars = attachment.base64.count
          logger.info(
            "agent.tool.attachment.inject",
            metadata: [
              "round": "\(round)",
              "tool": "\(inv.name)",
              "mime_type": "\(attachment.mimeType)",
              "base64_chars": "\(b64chars)",
              "source_path": "\(attachment.sourcePath ?? "nil")",
            ])
          let parts: [ScribeContentPart] = [
            .text((attachment.sourcePath ?? attachment.filename).map { "\($0):" } ?? "Attached media:"),
            .image(url: attachment.dataUri, detail: nil),
          ]
          let imageMsg = ScribeMessage(role: .user, contentParts: parts).toChatMessage()
          currentContext.messages.append(imageMsg)
          newMessages.append(imageMsg)
        }
      }
    }
  }
}

// MARK: - Round outcome

private enum RoundOutcome: Sendable, Equatable {
  case completed
  case toolCalls([ToolInvocation])
}

// MARK: - Single round

/// Execute one LLM round: stream an assistant response, accumulate it, and
/// return the outcome (completed or tool calls).
private func runSingleRound(
  context: inout AgentContext,
  config: AgentLoopConfig,
  emit: @escaping @Sendable (AgentEvent) -> Void,
  logger: Logger,
  clock: ContinuousClock,
  round: Int,
  abortObserver: some AbortObserver
) async throws -> RoundOutcome {

  // ── Build request ────────────────────────────────────
  let requestBody = Components.Schemas.CreateChatCompletionRequest(
    model: config.model,
    messages: context.messages,
    stream: true,
    temperature: Float(config.temperature),
    maxTokens: nil,
    tools: config.chatTools,
    toolChoice: nil,
    streamOptions: .init(includeUsage: true),
    reasoning: config.reasoningEnabled == nil
      ? nil : Components.Schemas.ChatCompletionReasoning(enabled: config.reasoningEnabled)
  )

  // ── Send HTTP request ────────────────────────────────
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

  // ── Stream processor ─────────────────────────────────
  var turn = StreamedAssistantTurn()
  var processor = StreamProcessor(
    onEvent: emit,
    logger: logger,
    abortObserver: abortObserver,
    streamWallStart: clock.now
  )
  try await processor.process(httpBody: httpBody, httpStart: httpStart, turn: &turn)

  // ── Finalize ─────────────────────────────────────────
  let toolInvocations = turn.resolvedToolCalls()
  let assistantText = turn.text.isEmpty ? "" : turn.text
  let assistantReasoning = turn.reasoningText.isEmpty ? nil : turn.reasoningText

  let assistantMessage = Components.Schemas.ChatMessage(
    role: .assistant,
    content: .case1(assistantText),
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

  // Emit usage if available
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
        "answer_chars": "\(assistantText.count)",
        "reasoning_chars": "\(assistantReasoning?.count ?? 0)",
      ])
    return .completed
  }

  return .toolCalls(toolInvocations)
}

// MARK: - Attachment-overflow recovery

/// Heuristic: does this HTTP error look like a context-length / prompt-too-long
/// failure that we can recover from by dropping over-sized tool attachments?
///
/// Provider phrasing varies — match a few common substrings rather than parse
/// the JSON. We intentionally only recover from this specific failure shape;
/// other 400s (bad tool args, schema mismatches) bubble up so the user sees
/// the real cause.
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

/// Roll back the trailing synthetic-attachment user messages and replace the
/// preceding `.tool` result with an error JSON so the model can react.
///
/// The shape we're rolling back is the one produced by the tool-loop in this
/// file: a `.tool` message followed by zero or more `.user` messages whose
/// content is multi-part (`.case2`, i.e. image/text parts). When the next LLM
/// round explodes with a context-length error, the attachment we injected is
/// the most likely culprit.
///
/// Returns the reason string suitable for the `.lifecycle(.recovered)` event,
/// or `nil` if no recoverable shape was found at the tail (in which case the
/// caller must propagate the original error).
func rollbackAttachmentOverflow(
  messages: inout [Components.Schemas.ChatMessage],
  newMessages: inout [Components.Schemas.ChatMessage],
  providerDetail: String
) -> String? {
  // Walk back past synthetic-attachment user messages (multi-part content).
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

  // The tool result immediately before the attachments is what overflowed.
  // Replace its content with a synthetic error so the model sees the
  // cause-and-effect and can self-correct on the next round.
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
  if let newIdx = newMessages.lastIndex(where: { $0.role == .tool && $0.toolCallId == original.toolCallId })
  {
    newMessages[newIdx] = replacement
  }
  return "tool output exceeded model context — dropped \(droppedAttachments) attachment(s)"
}
