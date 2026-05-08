import Foundation
import Logging
import OpenAPIRuntime
import ScribeLLM

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
    let streamResult = try await processStreamChunks(
      httpBody,
      httpStart: httpStart,
      turn: &turn,
      logger: logger,
      shouldAbortTurn: shouldAbortTurn
    )
    return finalizeTurn(turn, result: streamResult, messages: &messages, logger: logger)
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
      toolChoice: nil,
      streamOptions: .init(includeUsage: true),
      reasoning: Components.Schemas.ChatCompletionReasoning(enabled: true)
    )
  }

  private func sendStreamingRequest(
    _ requestBody: Components.Schemas.CreateChatCompletionRequest,
    logger: Logger
  ) async throws -> (HTTPBody, ContinuousClock.Instant) {
    let httpStart = clock.now
    logger.info(
      "agent.http.request",
      metadata: [
        "messages": "\(requestBody.messages.count)"
      ])
    let response = try await client.createChatCompletion(body: .json(requestBody))
    let httpElapsedMs = elapsedMs(since: httpStart)
    switch response {
    case .ok(let ok):
      logger.debug(
        "agent.http.response",
        metadata: [
          "status": "200",
          "elapsed_ms": "\(httpElapsedMs)",
        ])
      return (try ok.body.textEventStream, httpStart)
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
        "agent.http.response",
        metadata: [
          "status": "\(code)",
          "elapsed_ms": "\(httpElapsedMs)",
          "body_snippet": "\(detailSnippet.replacingOccurrences(of: "\"", with: "\\\""))",
        ])
      throw ScribeError.apiHTTPError(
        statusCode: code,
        detail: detail,
        hint: hint.isEmpty ? nil : hint
      )
    }
  }

  /// Accumulated metadata from processing a single SSE stream.
  private struct StreamProcessingResult {
    var lastUsage: Components.Schemas.CompletionUsage?
    var streamStarted: Bool = false
    var streamSection: AssistantStreamSection?
    var firstStreamContentAt: ContinuousClock.Instant?
    var decodedChunkCount: Int = 0
    var skippedChunkCount: Int = 0
    let streamWallStart: ContinuousClock.Instant
  }

  private func processStreamChunks(
    _ httpBody: HTTPBody,
    httpStart: ContinuousClock.Instant,
    turn: inout StreamedAssistantTurn,
    logger: Logger,
    shouldAbortTurn: @escaping @Sendable () -> Bool
  ) async throws -> StreamProcessingResult {
    let sseStream = httpBody.asDecodedServerSentEvents(
      while: { $0 != HTTPBody.ByteChunk("[DONE]".utf8) }
    )
    let jsonDecoder = JSONDecoder()

    var result = StreamProcessingResult(streamWallStart: clock.now)
    var loggedFirstChunk = false
    // Periodic progress log every N decoded chunks. We deliberately do NOT log every chunk
    // (high-throughput streams produce hundreds per turn — per-chunk lines drown out the
    // signal). The first/last events plus periodic progress give a trace of stream health.
    let streamProgressEvery = 200

    for try await sse in sseStream {
      if shouldAbortTurn() {
        logger.notice(
          "agent.stream.abort",
          metadata: [
            "where": "mid-stream",
            "chunks": "\(result.decodedChunkCount)",
            "had_visible_tokens": "\(result.streamStarted)",
          ])
        if result.streamStarted {
          onEvent(.finalizeAssistantStream)
        }
        throw AgentTurnInterruptedError()
      }
      guard let raw = sse.data?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty
      else { continue }
      if raw == "[DONE]" { break }
      let chunk: Components.Schemas.ChatCompletionChunk
      do {
        chunk = try jsonDecoder.decode(
          Components.Schemas.ChatCompletionChunk.self,
          from: Data(raw.utf8)
        )
      } catch {
        result.skippedChunkCount += 1
        logger.warning(
          "agent.stream.unreadable-chunk",
          metadata: [
            "chunk_index": "\(result.decodedChunkCount + 1)",
            "err": "\(error.localizedDescription)",
            "raw_prefix": "\(raw.prefix(120).replacingOccurrences(of: "\"", with: "\\\""))",
          ])
        onEvent(.skippedUnreadableStreamLine)
        continue
      }
      result.decodedChunkCount += 1
      if !loggedFirstChunk {
        loggedFirstChunk = true
        let firstChunkMs = elapsedMs(since: httpStart)
        logger.debug(
          "agent.stream.first-chunk",
          metadata: [
            "ttfb_ms": "\(firstChunkMs)"
          ])
      } else if result.decodedChunkCount % streamProgressEvery == 0 {
        let elapsedMs = elapsedMs(since: result.streamWallStart)
        let chunksPerSec = Double(result.decodedChunkCount) / (Double(elapsedMs) / 1000.0)
        logger.trace(
          "agent.stream.progress",
          metadata: [
            "chunks": "\(result.decodedChunkCount)",
            "elapsed_ms": "\(elapsedMs)",
            "chunks_per_s": "\(String(format: "%.1f", chunksPerSec))",
          ])
      }
      if let u = chunk.usage {
        result.lastUsage = u
      }
      for choice in chunk.choices ?? [] {
        guard let delta = choice.delta else { continue }
        for r in [delta.reasoningContent, delta.reasoning].compactMap({ $0 }).filter({ !$0.isEmpty }) {
          if result.firstStreamContentAt == nil { result.firstStreamContentAt = clock.now }
          result.streamStarted = true
          if case .some(.reasoning) = result.streamSection {
          } else {
            onEvent(.enterAssistantSection(.reasoning, previous: result.streamSection))
            result.streamSection = .reasoning
          }
          onEvent(.appendAssistantText(.reasoning, text: r))
        }
        if let t = delta.content, !t.isEmpty {
          if result.firstStreamContentAt == nil { result.firstStreamContentAt = clock.now }
          result.streamStarted = true
          if case .some(.answer) = result.streamSection {
          } else {
            onEvent(.enterAssistantSection(.answer, previous: result.streamSection))
            result.streamSection = .answer
          }
          onEvent(.appendAssistantText(.answer, text: t))
        }
      }
      turn.apply(chunk: chunk)
    }

    if result.streamStarted {
      onEvent(.finalizeAssistantStream)
    } else if turn.text.isEmpty, turn.resolvedToolCalls().isEmpty {
      logger.notice(
        "agent.stream.empty",
        metadata: [
          "chunks": "\(result.decodedChunkCount)"
        ])
      onEvent(.emptyAssistantTurn)
    }

    return result
  }

  private func finalizeTurn(
    _ turn: StreamedAssistantTurn,
    result: StreamProcessingResult,
    messages: inout [Components.Schemas.ChatMessage],
    logger: Logger
  ) -> RoundOutcome {
    let streamElapsedMs = elapsedMs(since: result.streamWallStart)
    if let u = result.lastUsage {
      let genStart = result.firstStreamContentAt ?? result.streamWallStart
      let genSec = elapsedSeconds(since: genStart)
      let tps: Double? = {
        guard let c = u.completionTokens, c > 0 else { return nil }
        return Double(c) / max(0.001, genSec)
      }()
      logger.debug(
        "agent.stream.end",
        metadata: [
          "chunks": "\(result.decodedChunkCount)",
          "skipped": "\(result.skippedChunkCount)",
          "elapsed_ms": "\(streamElapsedMs)",
          "prompt_tokens": "\(u.promptTokens.map(String.init(describing:)) ?? "nil")",
          "completion_tokens": "\(u.completionTokens.map(String.init(describing:)) ?? "nil")",
          "tps": "\(tps.map { String(format: "%.1f", $0) } ?? "nil")",
        ])
      onEvent(.usage(u, tokensPerSecond: tps))
    } else {
      logger.debug(
        "agent.stream.end",
        metadata: [
          "chunks": "\(result.decodedChunkCount)",
          "skipped": "\(result.skippedChunkCount)",
          "elapsed_ms": "\(streamElapsedMs)",
          "usage": "missing",
        ])
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
        "agent.assistant.final",
        metadata: [
          "answer_chars": "\(assistantText.count)",
          "reasoning_chars": "\(assistantReasoning?.count ?? 0)",
        ])
      onEvent(.blankLine)
      return .completed
    }

    return .toolCalls(
      toolInvocations.map {
        ToolInvocation(id: $0.id, name: $0.name, arguments: $0.arguments)
      })
  }

  // MARK: - Timing helpers (ContinuousClock)

  /// Milliseconds since `start`, using native `Duration` division (no manual
  /// component extraction, avoiding `Double(Int64)` precision loss).
  private func elapsedMs(since start: ContinuousClock.Instant) -> Int {
    Int((clock.now - start) / .milliseconds(1))
  }

  /// Seconds since `start` as `Double`, using native `Duration` division.
  private func elapsedSeconds(since start: ContinuousClock.Instant) -> Double {
    (clock.now - start) / .seconds(1)
  }
}
