import Foundation
import Logging
import OpenAPIRuntime
import ScribeLLM

// MARK: - Error & outcome types for the agent harness

public struct AgentAPIError: Error, LocalizedError {
  public var errorDescription: String?

  public init(description: String) {
    self.errorDescription = description
  }
}

/// Thrown when an interactive host asks to stop the current model/tool round.
public struct AgentTurnInterruptedError: Error, Sendable {}

/// Result of ``AgentHarness/runModelTurn(messages:logger:shouldAbortTurn:)``.
public enum ModelTurnOutcome: Sendable, Equatable {
  case completed
  case hitToolRoundLimit
}

// MARK: - AgentHarness

public struct AgentHarness {
  public var client: Client
  public var model: String
  public var maxToolRounds: Int
  private let output: any ScribeAgentOutput
  private let tools = AgentTools.all()
  private let runner = ToolRunner()

  public init(
    output: any ScribeAgentOutput,
    client: Client,
    model: String,
    maxToolRounds: Int
  ) {
    self.output = output
    self.client = client
    self.model = model
    self.maxToolRounds = maxToolRounds
  }

  public func runModelTurn(
    messages: inout [Components.Schemas.ChatMessage],
    logger: Logger,
    shouldAbortTurn: @escaping @Sendable () -> Bool = { false }
  ) async throws
    -> ModelTurnOutcome
  {
    logger.debug(
      """
      event=agent.turn.start \
      model=\(model) \
      messages=\(messages.count) \
      max_tool_rounds=\(maxToolRounds)
      """
    )
    for round in 0..<maxToolRounds {
      let roundNum = round + 1
      if shouldAbortTurn() {
        logger.debug(
          """
          event=agent.abort \
          where=before-http \
          round=\(roundNum)
          """
        )
        throw AgentTurnInterruptedError()
      }
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
        round=\(roundNum) \
        payload_messages=\(messages.count)
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
          round=\(roundNum) \
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
          round=\(roundNum) \
          status=\(code) \
          elapsed_ms=\(httpElapsedMs) \
          body_snippet="\(detailSnippet.replacingOccurrences(of: "\"", with: "\\\""))"
          """
        )
        throw AgentAPIError(
          description:
            "chat/completions returned HTTP \(code)"
            + (detail.isEmpty ? "" : " — \(detail)")
            + ".\(hint)"
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
            try output.finalizeAssistantStreamIfNeeded(streamHadVisibleTokens: true)
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
          try output.printSkippedUnreadableStreamLine()
          continue
        }
        decodedChunkCount += 1
        if !loggedFirstChunk {
          loggedFirstChunk = true
          let firstChunkMs = Int(Date().timeIntervalSince(httpStart) * 1000)
          logger.debug(
            """
            event=agent.stream.first-chunk \
            round=\(roundNum) \
            ttfb_ms=\(firstChunkMs)
            """
          )
        } else if decodedChunkCount % streamProgressEvery == 0 {
          let elapsedMs = max(1, Int(Date().timeIntervalSince(streamWallStart) * 1000))
          let chunksPerSec = Double(decodedChunkCount) / (Double(elapsedMs) / 1000.0)
          logger.trace(
            """
            event=agent.stream.progress \
            round=\(roundNum) \
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
              try output.enterAssistantStreamSection(
                .reasoning, previous: streamSection)
              streamSection = .reasoning
            }
            try output.appendAssistantStreamText(.reasoning, text: r)
          }
          if let t = delta.content, !t.isEmpty {
            if firstStreamContentAt == nil { firstStreamContentAt = Date() }
            streamStarted = true
            if case .some(.answer) = streamSection {
            } else {
              try output.enterAssistantStreamSection(
                .answer, previous: streamSection)
              streamSection = .answer
            }
            try output.appendAssistantStreamText(.answer, text: t)
          }
        }
        turn.apply(chunk: chunk)
      }
      if streamStarted {
        try output.finalizeAssistantStreamIfNeeded(streamHadVisibleTokens: true)
      } else if turn.text.isEmpty, turn.resolvedToolCalls().isEmpty {
        logger.notice(
          """
          event=agent.stream.empty \
          chunks=\(decodedChunkCount)
          """
        )
        try output.printEmptyAssistantTurn()
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
          round=\(roundNum) \
          chunks=\(decodedChunkCount) \
          skipped=\(skippedChunkCount) \
          elapsed_ms=\(streamElapsedMs) \
          prompt_tokens=\(u.promptTokens.map(String.init(describing:)) ?? "nil") \
          completion_tokens=\(u.completionTokens.map(String.init(describing:)) ?? "nil") \
          tps=\(tps.map { String(format: "%.1f", $0) } ?? "nil")
          """
        )
        try output.emitUsage(usage: u, outputTokensPerSecond: tps)
      } else {
        logger.debug(
          """
          event=agent.stream.end \
          round=\(roundNum) \
          chunks=\(decodedChunkCount) \
          skipped=\(skippedChunkCount) \
          elapsed_ms=\(streamElapsedMs) \
          usage=missing
          """
        )
      }

      if shouldAbortTurn() {
        logger.debug(
          """
          event=agent.abort \
          where=post-stream-pre-tools \
          round=\(roundNum)
          """
        )
        throw AgentTurnInterruptedError()
      }

      let messagesCountBeforeAssistant = messages.count

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
          round=\(roundNum) \
          answer_chars=\(assistantText.count) \
          reasoning_chars=\(assistantReasoning?.count ?? 0)
          """
        )
        try output.printBlankLine()
        return .completed
      }

      logger.info(
        """
        event=agent.tool.round \
        round=\(roundNum) \
        tool_count=\(toolInvocations.count) \
        tools=\(toolInvocations.map(\.name).joined(separator: ","))
        """
      )
      try output.printToolRoundHeader(round: roundNum, toolNames: toolInvocations.map(\.name))

      for inv in toolInvocations {
        if shouldAbortTurn() {
          logger.notice(
            """
            event=agent.abort \
            where=pre-tool \
            tool=\(inv.name) \
            round=\(roundNum)
            """
          )
          messages.removeSubrange(messagesCountBeforeAssistant..<messages.endIndex)
          throw AgentTurnInterruptedError()
        }
        let toolStarted = Date()
        let jsonOutput = await runner.run(name: inv.name, argumentsJSON: inv.arguments)
        let elapsedMs = Int(Date().timeIntervalSince(toolStarted) * 1000)
        let unknown = jsonOutput.contains("unknown tool")
        if unknown {
          logger.warning(
            """
            event=agent.tool.unknown \
            tool=\(inv.name) \
            round=\(roundNum)
            """
          )
        }
        logger.debug(
          """
          event=agent.tool.invoke \
          round=\(roundNum) \
          tool=\(inv.name) \
          args_chars=\(inv.arguments.count) \
          output_chars=\(jsonOutput.count) \
          elapsed_ms=\(elapsedMs) \
          unknown=\(unknown)
          """
        )
        // Tool-specific structured detail. Right now only `read_file` carries enough
        // metadata to be worth a dedicated log line, but the same pattern can be extended
        // to other tools (`shell` exit code, `edit_file` chars-replaced, etc.) without
        // changing the harness's main control flow.
        if inv.name == "read_file" {
          let summary = ToolInvocationFormatting.readFileLogSummary(jsonOutput: jsonOutput)
          logger.debug(
            """
            event=agent.tool.read_file \
            round=\(roundNum) \
            \(summary)
            """
          )
        }
        let argSummary = ToolInvocationFormatting.argumentSummary(
          name: inv.name, argumentsJSON: inv.arguments)
        let lines = ToolInvocationFormatting.outputLines(name: inv.name, jsonOutput: jsonOutput)
        try output.printToolInvocation(name: inv.name, argumentSummary: argSummary, outputLines: lines)
        try output.printBlankLine()
        let toolMsg = Components.Schemas.ChatMessage(
          role: .tool,
          content: jsonOutput,
          name: nil,
          toolCalls: nil,
          toolCallId: inv.id
        )
        messages.append(toolMsg)
      }
      logger.trace(
        """
        event=agent.tool.round.end \
        round=\(roundNum) \
        messages=\(messages.count)
        """
      )
    }
    logger.notice(
      """
      event=agent.turn.tool-round-limit \
      max=\(maxToolRounds)
      """
    )
    try output.printMaxToolRoundsExceeded(max: maxToolRounds)
    return .hitToolRoundLimit
  }
}
