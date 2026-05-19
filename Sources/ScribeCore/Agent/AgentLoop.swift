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
  emit: @escaping @Sendable (TranscriptEvent) -> Void,
  log: Logger,
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

  while true {
    round += 1
    if abortObserver.isAborted() {
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
        abortObserver: abortObserver
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

    if abortObserver.isAborted() {
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
        log.notice(
          "agent.turn.tool-round-limit",
          metadata: ["max": "\(config.maxToolRounds)"])
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

      for inv in invocations {
        if abortObserver.isAborted() {
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
          jsonOutput = try await config.toolExecutor.execute(
            inv,
            workingDirectory: config.workingDirectory,
            log: log,
            abort: abortObserver)
        } catch is AgentTurnInterruptedError {
          currentContext.messages.removeSubrange(messagesCountBeforeRound..<currentContext.messages.endIndex)
          newMessages.removeSubrange(newMessages.count - roundMessages.count..<newMessages.count)
          return (newMessages, .interrupted)
        } catch let ScribeError.toolUnknown(name) {
          log.warning("agent.tool.unknown", metadata: ["tool": "\(name)", "round": "\(round)"])
          jsonOutput = ToolRegistry.jsonError("unknown tool \(name)")
        } catch {
          // Defensive: a custom ToolExecutor may throw arbitrary errors.
          // Surface them to the model as a JSON-encoded tool failure so the
          // assistant can self-correct, rather than aborting the turn.
          log.warning(
            "agent.tool.executor.error",
            metadata: [
              "tool": "\(inv.name)", "round": "\(round)",
              "err": "\(String(describing: error).replacingOccurrences(of: "\"", with: "\\\""))",
            ])
          jsonOutput = ToolRegistry.jsonError(String(describing: error))
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
  log.info(
    "agent.http.request",
    metadata: [
      "messages": "\(requestBody.messages.count)",
      "reasoning_enabled": "\(String(describing: config.reasoningEnabled))",
    ])
  let response = try await config.client.createChatCompletion(body: .json(requestBody))

  let httpBody: HTTPBody
  switch response {
  case .ok(let ok):
    log.debug(
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
    log.log(
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
    logger: log,
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
      "agent.stream.end",
      metadata: [
        "chunks": "\(processor.decodedChunkCount)",
        "skipped": "\(processor.skippedChunkCount)",
        "prompt_tokens": "\(u.promptTokens.map(String.init(describing:)) ?? "nil")",
        "completion_tokens": "\(u.completionTokens.map(String.init(describing:)) ?? "nil")",
        "tps": "\(tps.map { String(format: "%.1f", $0) } ?? "nil")",
      ])
    emit(.usage(ScribeUsage(u), tokensPerSecond: tps))
  }

  if toolInvocations.isEmpty {
    log.info(
      "agent.assistant.final",
      metadata: [
        "answer_chars": "\(assistantText.count)",
        "reasoning_chars": "\(assistantReasoning?.count ?? 0)",
      ])
    return .completed
  }

  return .toolCalls(toolInvocations)
}
