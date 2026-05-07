import Foundation
import Logging
import OpenAPIRuntime
import ScribeLLM

// MARK: - AgentHarness

/// Orchestrates a single model turn: sends messages to the LLM, streams the
/// response, and executes tool calls in a loop until the assistant produces a
/// final answer or the tool-round limit is reached.
///
/// ## Agent events
///
/// | Event | Sample fields | When it fires |
/// |---|---|---|
/// | `agent.turn.dispatch` | `turn chars` | Coordinator pulled a non-empty user line from the gate and is starting a model turn. |
/// | `agent.turn.start` | `model messages max_tool_rounds` | First action inside `runModelTurn`. |
/// | `agent.http.request` | `round payload_messages` | Streaming POST to `chat/completions` was issued. |
/// | `agent.http.response` | `round status elapsed [body_snippet]` | HTTP response received. `status=200` for success; non-200 includes `body_snippet`. |
/// | `agent.stream.first-chunk` | `round ttfb_ms` | First decoded SSE chunk arrived. `ttfb_ms` is wall time since the request was issued. |
/// | `agent.stream.progress` | `round chunks elapsed chunks_per_s` | Periodic progress every 200 chunks. (Per-chunk lines are intentionally not emitted — they drown the signal during long streams.) |
/// | `agent.stream.end` | `round chunks skipped elapsed prompt_tokens completion_tokens tps` | Stream finished cleanly; usage block included when the server provided one. |
/// | `agent.stream.empty` | `chunks` | Stream produced no tokens and no tool calls. |
/// | `agent.stream.unreadable-chunk` | `chunk_index err raw_prefix` | An SSE event failed JSON decoding (decoder skipped). |
/// | `agent.stream.abort` | `where chunks had_visible_tokens` | Turn was aborted while streaming. `where` is `mid-stream` or `post-stream`. |
/// | `agent.assistant.final` | `round answer_chars reasoning_chars` | Assistant produced a final reply with no tool calls. |
/// | `agent.tool.round` | `round tool_count tools` | Assistant requested tool calls; runner is about to execute them. |
/// | `agent.tool.invoke` | `round tool args_chars output_chars elapsed unknown` | A single tool call completed. |
/// | `agent.tool.unknown` | `round tool` | Tool runner reported the call name as unknown. |
/// | `agent.tool.round.end` | `round messages` | All tool calls in a round done; loop will request the next model response. |
/// | `agent.turn.end` | `turn status [elapsed limit err]` | Coordinator's outcome line per turn. `status` is `completed`, `tool-round-limit`, `interrupted`, or `error`. |
/// | `agent.turn.tool-round-limit` | `max` | Hit the configured tool-round ceiling without a clean reply. |
/// | `agent.abort` | `where round [tool]` | Cooperative abort fired between phases (`before-http`, `post-stream-pre-tools`, `pre-tool`). |
public struct AgentHarness: Sendable, AgentHarnessProtocol {
  public var client: Client
  public var model: String
  private let onEvent: @Sendable (TranscriptEvent) -> Void
  private let tools: [Components.Schemas.ChatTool]
  private let clock = ContinuousClock()

  public init(
    onEvent: @escaping @Sendable (TranscriptEvent) -> Void,
    client: Client,
    model: String,
    tools: [Components.Schemas.ChatTool]
  ) {
    self.onEvent = onEvent
    self.client = client
    self.model = model
    self.tools = tools
  }

  public func runRound(
    messages: inout [Components.Schemas.ChatMessage],
    logger: Logger,
    shouldAbortTurn: @escaping @Sendable () -> Bool = { false }
  ) async throws -> RoundOutcome {
    let requestBody = buildRequest(messages: messages)
    let (httpBody, httpStart) = try await sendStreamingRequest(requestBody, logger: logger)

    var turn = StreamedAssistantTurn()
    var processor = StreamProcessor(
      onEvent: onEvent,
      logger: logger,
      shouldAbortTurn: shouldAbortTurn,
      streamWallStart: clock.now
    )
    try await processor.process(httpBody: httpBody, httpStart: httpStart, turn: &turn)
    return finalizeTurn(turn, processor: processor, messages: &messages, logger: logger)
  }

  // MARK: - Private helpers

  private func buildRequest(
    messages: [Components.Schemas.ChatMessage]
  ) -> Components.Schemas.CreateChatCompletionRequest {
    Components.Schemas.CreateChatCompletionRequest(
      model: model,
      messages: messages,
      stream: true,
      temperature: 0,
      maxTokens: nil,
      tools: tools,
      toolChoice: .case1("auto"),
      streamOptions: .init(includeUsage: true),
      reasoning: nil
    )
  }

  private func sendStreamingRequest(
    _ requestBody: Components.Schemas.CreateChatCompletionRequest,
    logger: Logger
  ) async throws -> (HTTPBody, ContinuousClock.Instant) {
    let httpStart = clock.now
    logger.info(
      """
      event=agent.http.request \
      messages=\(requestBody.messages.count)
      """
    )
    let response = try await client.createChatCompletion(body: .json(requestBody))

    switch response {
    case .ok(let ok):
      logger.debug(
        """
        event=agent.http.response \
        status=200 \
        elapsed=\(clock.now - httpStart)
        """
      )
      return (try ok.body.textEventStream, httpStart)
    case .undocumented(statusCode: let code, let payload):
      var detail = ""
      if let body = payload.body {
        let chunk = try await HTTPBody.ByteChunk(collecting: body, upTo: 4096)
        detail = String(decoding: chunk, as: UTF8.self)
      }
      let hint: String = {
        let d = detail.lowercased()
        if d.contains("model"), d.contains("not found") {
          return
            " The configured model was not found. Set `agent.model` in `scribe-config.json` to an installed model, or run e.g. `ollama pull llama3.2`."
        }
        if code == 404 {
          return
            " Set `api.baseUrl` in `scribe-config.json` to the host only (no `/v1`), e.g. http://127.0.0.1:11434 for Ollama."
        }
        return ""
      }()
      let detailSnippet =
        detail.count > 512 ? String(detail.prefix(512)) + "…(\(detail.count) chars)" : detail
      let level: Logger.Level = code >= 500 ? .error : .warning
      logger.log(
        level: level,
        """
        event=agent.http.response \
        status=\(code) \
        elapsed=\((clock.now - httpStart) / .milliseconds(1)) \
        body_snippet="\(detailSnippet.replacingOccurrences(of: "\"", with: "\\\""))"
        """
      )
      throw ScribeError.apiHTTPError(
        statusCode: code,
        detail: detail,
        hint: hint.isEmpty ? nil : hint
      )
    }
  }

  private func finalizeTurn(
    _ turn: StreamedAssistantTurn,
    processor: StreamProcessor,
    messages: inout [Components.Schemas.ChatMessage],
    logger: Logger
  ) -> RoundOutcome {
    let streamElapsedMs = Int((clock.now - processor.streamWallStart) / .milliseconds(1))
    if let u = processor.lastUsage {
      let genStart = processor.firstStreamContentAt ?? processor.streamWallStart
      let genSec = (clock.now - genStart) / .seconds(1)
      let tps: Double? = {
        guard let c = u.completionTokens, c > 0 else { return nil }
        return Double(c) / max(0.001, genSec)
      }()
      logger.debug(
        """
        event=agent.stream.end \
        chunks=\(processor.decodedChunkCount) \
        skipped=\(processor.skippedChunkCount) \
        elapsed=\(streamElapsedMs) \
        prompt_tokens=\(u.promptTokens.map(String.init(describing:)) ?? "nil") \
        completion_tokens=\(u.completionTokens.map(String.init(describing:)) ?? "nil") \
        tps=\(tps.map { String(format: "%.1f", $0) } ?? "nil")
        """
      )
      onEvent(.usage(u, tokensPerSecond: tps))
    } else {
      logger.debug(
        """
        event=agent.stream.end \
        chunks=\(processor.decodedChunkCount) \
        skipped=\(processor.skippedChunkCount) \
        elapsed=\(streamElapsedMs) \
        usage=missing
        """
      )
    }

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
            function: .init(
              name: inv.name,
              arguments: inv.arguments
            )
          )
        },
      toolCallId: nil,
      reasoningContent: assistantReasoning
    )
    messages.append(assistantMessage)

    if toolInvocations.isEmpty {
      logger.info(
        """
        event=agent.assistant.final \
        answer_chars=\(assistantText.count) \
        reasoning_chars=\(assistantReasoning?.count ?? 0)
        """
      )
      onEvent(.blankLine)
      return .completed
    }

    return .toolCalls(
      toolInvocations.map {
        ToolInvocation(id: $0.id, name: $0.name, arguments: $0.arguments)
      })
  }

}
