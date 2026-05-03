import Foundation
import Logging
import OpenAPIRuntime
import ScribeLLM

// MARK: - Error & outcome types for the agent harness

public enum ScribeError: Error, Sendable, LocalizedError, Equatable {
  case configuration(key: String?, reason: String)
  case apiHTTPError(statusCode: Int, detail: String, hint: String?)
  case sessionCorrupted(reason: String)
  case resumeNotFound(specifier: String)
  case resumeAmbiguous(specifier: String)
  case invalidInput(message: String)
  case toolRoundLimit(max: Int)
  case generic(String)

  public var errorDescription: String? {
    switch self {
    case .configuration(_, let reason):
      return reason
    case .apiHTTPError(let statusCode, let detail, let hint):
      var msg = "chat/completions returned HTTP \(statusCode)"
      if !detail.isEmpty {
        msg += " — \(detail)"
      }
      if let hint, !hint.isEmpty {
        msg += ".\(hint)"
      }
      return msg
    case .sessionCorrupted(let reason):
      return reason
    case .resumeNotFound(let specifier):
      return "No session matches \"\(specifier)\". Try `scribe chat --sessions`."
    case .resumeAmbiguous(let specifier):
      return "Ambiguous session prefix \"\(specifier)\"; use a longer id or a full path."
    case .invalidInput(let message):
      return message
    case .toolRoundLimit(let max):
      return "Stopped after reaching the configured tool round limit (\(max))."
    case .generic(let message):
      return message
    }
  }
}

/// Thrown when an interactive host asks to stop the current model/tool round.
public struct AgentTurnInterruptedError: Error, Sendable {}

/// Result of ``AgentLoop/runModelTurn(messages:logger:shouldAbortTurn:)``.
public enum ModelTurnOutcome: Sendable, Equatable {
  case completed
  case hitToolRoundLimit
}

/// Result of a single LLM round from ``AgentHarness/runRound(messages:logger:shouldAbortTurn:)``.
public enum RoundOutcome: Sendable, Equatable {
  case completed
  case toolCalls([ToolInvocation])
}

/// A resolved tool call produced by the assistant in a single round.
public struct ToolInvocation: Sendable, Equatable {
  public let id: String
  public let name: String
  public let arguments: String

  public init(id: String, name: String, arguments: String) {
    self.id = id
    self.name = name
    self.arguments = arguments
  }
}

// MARK: - AgentHarness

public protocol AgentHarnessProtocol: Sendable {
  var model: String { get }

  func runRound(
    messages: inout [Components.Schemas.ChatMessage],
    logger: Logger,
    shouldAbortTurn: @escaping @Sendable () -> Bool
  ) async throws -> RoundOutcome
}

public struct AgentHarness: Sendable, AgentHarnessProtocol {
  public var client: Client
  public var model: String
  private let onEvent: @Sendable (TranscriptEvent) -> Void
  private let tools: [Components.Schemas.ChatTool]

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
    let requestBody = Components.Schemas.CreateChatCompletionRequest(
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
    let chatClient = client
    let httpStart = Date()
    logger.info(
      """
      event=agent.http.request \
      messages=\(messages.count)
      """
    )
    let response = try await chatClient.createChatCompletion(body: .json(requestBody))
    let httpElapsedMs = Int(Date().timeIntervalSince(httpStart) * 1000)
    let httpBody: HTTPBody
    switch response {
    case .ok(let ok):
      httpBody = try ok.body.textEventStream
      logger.debug(
        """
        event=agent.http.response \
        status=200 \
        elapsed_ms=\(httpElapsedMs)
        """
      )
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
            " Unset `\(ScribeConfigBinding.agentModel.description)` in `scribe-config.json` to use the first model from /v1/models, set it to an installed name, or run e.g. `ollama pull llama3.2`."
        }
        if code == 404 {
          return
            " Set `\(ScribeConfigBinding.openAIBaseURL.description)` in `scribe-config.json` to the host only (no `/v1`), e.g. http://127.0.0.1:11434 for Ollama."
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
        elapsed_ms=\(httpElapsedMs) \
        body_snippet="\(detailSnippet.replacingOccurrences(of: "\"", with: "\\\""))"
        """
      )
      throw ScribeError.apiHTTPError(
        statusCode: code,
        detail: detail,
        hint: hint.isEmpty ? nil : hint
      )
    }
    let sseStream = httpBody.asDecodedServerSentEvents(
      while: { $0 != HTTPBody.ByteChunk("[DONE]".utf8) }
    )
    let jsonDecoder = JSONDecoder()

    var turn = StreamedAssistantTurn()
    var streamStarted = false
    var streamSection: AssistantStreamSection?
    var lastUsage: Components.Schemas.CompletionUsage?
    let streamWallStart = Date()
    var firstStreamContentAt: Date?
    var decodedChunkCount = 0
    var skippedChunkCount = 0
    var loggedFirstChunk = false
    // Periodic progress log every N decoded chunks. We deliberately do NOT log every chunk
    // (high-throughput streams produce hundreds per turn — per-chunk lines drown out the
    // signal). The first/last events plus periodic progress give a trace of stream health.
    let streamProgressEvery = 200
    for try await sse in sseStream {
      if shouldAbortTurn() {
        logger.notice(
          """
          event=agent.stream.abort \
          where=mid-stream \
          chunks=\(decodedChunkCount) \
          had_visible_tokens=\(streamStarted)
          """
        )
        if streamStarted {
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
        skippedChunkCount += 1
        logger.warning(
          """
          event=agent.stream.unreadable-chunk \
          chunk_index=\(decodedChunkCount + 1) \
          err="\(error.localizedDescription)" \
          raw_prefix="\(raw.prefix(120).replacingOccurrences(of: "\"", with: "\\\""))"
          """
        )
        onEvent(.skippedUnreadableStreamLine)
        continue
      }
      decodedChunkCount += 1
      if !loggedFirstChunk {
        loggedFirstChunk = true
        let firstChunkMs = Int(Date().timeIntervalSince(httpStart) * 1000)
        logger.debug(
          """
          event=agent.stream.first-chunk \
          ttfb_ms=\(firstChunkMs)
          """
        )
      } else if decodedChunkCount % streamProgressEvery == 0 {
        let elapsedMs = max(1, Int(Date().timeIntervalSince(streamWallStart) * 1000))
        let chunksPerSec = Double(decodedChunkCount) / (Double(elapsedMs) / 1000.0)
        logger.trace(
          """
          event=agent.stream.progress \
          chunks=\(decodedChunkCount) \
          elapsed_ms=\(elapsedMs) \
          chunks_per_s=\(String(format: "%.1f", chunksPerSec))
          """
        )
      }
      if let u = chunk.usage {
        lastUsage = u
      }
      for choice in chunk.choices ?? [] {
        guard let delta = choice.delta else { continue }
        for r in [delta.reasoningContent, delta.reasoning].compactMap({ $0 }).filter({ !$0.isEmpty }) {
          if firstStreamContentAt == nil { firstStreamContentAt = Date() }
          streamStarted = true
          if case .some(.reasoning) = streamSection {
          } else {
            onEvent(.enterAssistantSection(.reasoning, previous: streamSection))
            streamSection = .reasoning
          }
          onEvent(.appendAssistantText(.reasoning, text: r))
        }
        if let t = delta.content, !t.isEmpty {
          if firstStreamContentAt == nil { firstStreamContentAt = Date() }
          streamStarted = true
          if case .some(.answer) = streamSection {
          } else {
            onEvent(.enterAssistantSection(.answer, previous: streamSection))
            streamSection = .answer
          }
          onEvent(.appendAssistantText(.answer, text: t))
        }
      }
      turn.apply(chunk: chunk)
    }
    if streamStarted {
      onEvent(.finalizeAssistantStream)
    } else if turn.text.isEmpty, turn.resolvedToolCalls().isEmpty {
      logger.notice(
        """
        event=agent.stream.empty \
        chunks=\(decodedChunkCount)
        """
      )
      onEvent(.emptyAssistantTurn)
    }

    let streamWallEnd = Date()
    let streamElapsedMs = Int(streamWallEnd.timeIntervalSince(streamWallStart) * 1000)
    if let u = lastUsage {
      let genStart = firstStreamContentAt ?? streamWallStart
      let denom = max(0.001, streamWallEnd.timeIntervalSince(genStart))
      let tps: Double? = {
        guard let c = u.completionTokens, c > 0 else { return nil }
        return Double(c) / denom
      }()
      logger.debug(
        """
        event=agent.stream.end \
        chunks=\(decodedChunkCount) \
        skipped=\(skippedChunkCount) \
        elapsed_ms=\(streamElapsedMs) \
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
        chunks=\(decodedChunkCount) \
        skipped=\(skippedChunkCount) \
        elapsed_ms=\(streamElapsedMs) \
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
