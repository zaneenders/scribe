import Foundation
import Logging
import OpenAPIRuntime
import ScribeLLM

// MARK: - AgentContext / AgentLoopConfig

/// Immutable snapshot of agent state taken before a run starts.
struct AgentContext: Sendable {
  let systemPrompt: String
  var messages: [Components.Schemas.ChatMessage]
}

/// Bundled configuration for a single agent run — everything derived from
/// agent setup + per-call options.
struct AgentLoopConfig: Sendable {
  let model: String
  let client: Client
  let registry: ToolRegistry
  let temperature: Double
  let maxToolRounds: Int
  let workingDirectory: ScribeFilePath
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
  emit: @escaping @Sendable (TranscriptEvent) -> Void,
  log: Logger,
  shouldAbortTurn: @escaping @Sendable () -> Bool,
  abortNotifier: AbortNotifier? = nil
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

  while true {
    round += 1
    if shouldAbortTurn() {
      log.debug("agent.abort", metadata: ["where": "before-http", "round": "\(round)"])
      return (newMessages, .interrupted)
    }

    let messagesCountBeforeRound = currentContext.messages.count
    let roundResult: RoundOutcome
    do {
      roundResult = try await runSingleRound(
        context: &currentContext,
        config: config,
        emit: emit,
        log: log,
        clock: clock,
        round: round,
        shouldAbortTurn: shouldAbortTurn
      )
    } catch is AgentTurnInterruptedError {
      log.notice(
        "agent.abort",
        metadata: [
          "where": "mid-stream", "round": "\(round)",
        ])
      return (newMessages, .interrupted)
    }

    // Collect new messages from this round
    let roundMessages = Array(currentContext.messages[messagesCountBeforeRound...])
    newMessages.append(contentsOf: roundMessages)

    if shouldAbortTurn() {
      log.debug("agent.abort", metadata: ["where": "post-stream-pre-tools", "round": "\(round)"])
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
        log.notice("event=agent.turn.tool-round-limit max=\(config.maxToolRounds)")
        currentContext.messages.removeSubrange(messagesCountBeforeRound..<currentContext.messages.endIndex)
        newMessages.removeSubrange(newMessages.count - roundMessages.count..<newMessages.count)
        return (newMessages, .toolRoundLimit(rounds: config.maxToolRounds))
      }

      log.info(
        "agent.tool.round",
        metadata: [
          "round": "\(round)", "tool_count": "\(invocations.count)",
          "tools": "\(invocations.map(\.name).joined(separator: ","))",
        ])
      emit(.toolRoundHeader(round: round, toolNames: invocations.map(\.name)))

      for inv in invocations {
        if shouldAbortTurn() {
          log.notice(
            "agent.abort",
            metadata: [
              "where": "pre-tool", "tool": "\(inv.name)", "round": "\(round)",
            ])
          currentContext.messages.removeSubrange(messagesCountBeforeRound..<currentContext.messages.endIndex)
          newMessages.removeSubrange(newMessages.count - roundMessages.count..<newMessages.count)
          return (newMessages, .interrupted)
        }
        let toolStarted = clock.now
        let jsonOutput: String
        do {
          jsonOutput = try await config.registry.run(
            name: inv.name, arguments: inv.arguments,
            workingDirectory: config.workingDirectory,
            abortVia: shouldAbortTurn,
            abortNotifier: abortNotifier)
        } catch is AgentTurnInterruptedError {
          currentContext.messages.removeSubrange(messagesCountBeforeRound..<currentContext.messages.endIndex)
          newMessages.removeSubrange(newMessages.count - roundMessages.count..<newMessages.count)
          return (newMessages, .interrupted)
        } catch let ScribeError.toolUnknown(name) {
          log.warning("agent.tool.unknown", metadata: ["tool": "\(name)", "round": "\(round)"])
          jsonOutput = ToolRegistry.jsonError("unknown tool \(name)")
        }
        let elapsedMs = Int(toolStarted.duration(to: clock.now) / .milliseconds(1))
        log.debug(
          "agent.tool.invoke",
          metadata: [
            "round": "\(round)", "tool": "\(inv.name)",
            "args_chars": "\(inv.arguments.count)", "output_chars": "\(jsonOutput.count)",
            "elapsed_ms": "\(elapsedMs)",
          ])
        emit(.toolInvocation(name: inv.name, arguments: inv.arguments, output: jsonOutput))
        emit(.blankLine)
        let toolMsg = Components.Schemas.ChatMessage(
          role: .tool, content: jsonOutput, name: nil, toolCalls: nil, toolCallId: inv.id)
        currentContext.messages.append(toolMsg)
        newMessages.append(toolMsg)
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
  emit: @escaping @Sendable (TranscriptEvent) -> Void,
  log: Logger,
  clock: ContinuousClock,
  round: Int,
  shouldAbortTurn: @escaping @Sendable () -> Bool
) async throws -> RoundOutcome {

  // ── Build request ────────────────────────────────────
  let requestBody = Components.Schemas.CreateChatCompletionRequest(
    model: config.model,
    messages: context.messages,
    stream: true,
    temperature: Float(config.temperature),
    maxTokens: nil,
    tools: config.registry.chatTools,
    toolChoice: nil,
    streamOptions: .init(includeUsage: true),
    reasoning: Components.Schemas.ChatCompletionReasoning(enabled: true)
  )

  // ── Send HTTP request ────────────────────────────────
  let httpStart = clock.now
  log.info(
    """
    event=agent.http.request \
    messages=\(requestBody.messages.count)
    """)
  let response = try await config.client.createChatCompletion(body: .json(requestBody))

  let httpBody: HTTPBody
  switch response {
  case .ok(let ok):
    log.debug(
      """
      event=agent.http.response \
      status=200 \
      elapsed=\(clock.now - httpStart)
      """)
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
    log.log(
      level: level,
      """
      event=agent.http.response \
      status=\(code) \
      body_snippet="\(detailSnippet.replacingOccurrences(of: "\"", with: "\\\""))"
      """)
    throw ScribeError.apiHTTPError(statusCode: code, detail: detail, hint: hint.isEmpty ? nil : hint)
  }

  // ── Stream processor ─────────────────────────────────
  var turn = StreamedAssistantTurn()
  var processor = StreamProcessor(
    onEvent: emit,
    logger: log,
    shouldAbortTurn: shouldAbortTurn,
    streamWallStart: clock.now
  )
  try await processor.process(httpBody: httpBody, httpStart: httpStart, turn: &turn)

  // ── Finalize ─────────────────────────────────────────
  let toolInvocations = turn.resolvedToolCalls()
  let assistantText = turn.text.isEmpty ? "" : turn.text
  let assistantReasoning = turn.reasoningText.isEmpty ? nil : turn.reasoningText

  let assistantMessage = Components.Schemas.ChatMessage(
    role: .assistant,
    content: assistantText,
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
    log.debug(
      """
      event=agent.stream.end \
      chunks=\(processor.decodedChunkCount) \
      skipped=\(processor.skippedChunkCount) \
      prompt_tokens=\(u.promptTokens.map(String.init(describing:)) ?? "nil") \
      completion_tokens=\(u.completionTokens.map(String.init(describing:)) ?? "nil") \
      tps=\(tps.map { String(format: "%.1f", $0) } ?? "nil")
      """)
    emit(.usage(u, tokensPerSecond: tps))
  }

  if toolInvocations.isEmpty {
    log.info(
      """
      event=agent.assistant.final \
      answer_chars=\(assistantText.count) \
      reasoning_chars=\(assistantReasoning?.count ?? 0)
      """)
    emit(.blankLine)
    return .completed
  }

  return .toolCalls(toolInvocations)
}
