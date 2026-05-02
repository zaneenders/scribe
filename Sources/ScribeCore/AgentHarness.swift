import Foundation
import Logging
import OpenAPIRuntime
import ScribeLLM

private enum AbortOrHTTPResult<Response: Sendable>: Sendable {
  case response(Response)
  case aborted
}

/// Runs ``operation`` concurrently with a lightweight poll so ``shouldAbortTurn()`` can fire during slow HTTP setup (spinner) before any SSE bytes arrive.
private func raceHTTPAgainstTurnAbort<Response: Sendable>(
  shouldAbortTurn: @escaping @Sendable () -> Bool,
  operation: @Sendable @escaping () async throws -> Response
) async throws -> Response {
  try await withThrowingTaskGroup(of: AbortOrHTTPResult<Response>.self) { group in
    group.addTask {
      try await .response(operation())
    }
    group.addTask {
      while true {
        try await Task.sleep(for: .milliseconds(100))
        if shouldAbortTurn() { return .aborted }
      }
    }
    guard let first = try await group.next() else {
      group.cancelAll()
      throw AgentTurnInterruptedError()
    }
    switch first {
    case .aborted:
      group.cancelAll()
      throw AgentTurnInterruptedError()
    case .response(let value):
      group.cancelAll()
      return value
    }
  }
}

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
    logger.debug("Starting chat completion request (stream) model=\(model)")
    for round in 0..<maxToolRounds {
      if shouldAbortTurn() {
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
      let response = try await raceHTTPAgainstTurnAbort(shouldAbortTurn: shouldAbortTurn) {
        try await chatClient.createChatCompletion(body: .json(requestBody))
      }
      let httpBody: HTTPBody
      switch response {
      case .ok(let ok):
        httpBody = try ok.body.textEventStream
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
      for try await sse in sseStream {
        if shouldAbortTurn() {
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
          logger.debug("Skipping unreadable SSE JSON line: \(error.localizedDescription)")
          try output.printSkippedUnreadableStreamLine()
          continue
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
      if shouldAbortTurn() {
        if streamStarted {
          try output.finalizeAssistantStreamIfNeeded(streamHadVisibleTokens: true)
        }
        throw AgentTurnInterruptedError()
      }
      if streamStarted {
        try output.finalizeAssistantStreamIfNeeded(streamHadVisibleTokens: true)
      } else if turn.text.isEmpty, turn.resolvedToolCalls().isEmpty {
        try output.printEmptyAssistantTurn()
      }

      if let u = lastUsage {
        let streamWallEnd = Date()
        let genStart = firstStreamContentAt ?? streamWallStart
        let denom = max(0.001, streamWallEnd.timeIntervalSince(genStart))
        let tps: Double? = {
          guard let c = u.completionTokens, c > 0 else { return nil }
          return Double(c) / denom
        }()
        try output.emitUsage(usage: u, outputTokensPerSecond: tps)
      }

      if shouldAbortTurn() {
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
        try output.printBlankLine()
        return .completed
      }

      try output.printToolRoundHeader(round: round + 1, toolNames: toolInvocations.map(\.name))

      for inv in toolInvocations {
        if shouldAbortTurn() {
          messages.removeSubrange(messagesCountBeforeAssistant..<messages.endIndex)
          throw AgentTurnInterruptedError()
        }
        let jsonOutput = await runner.run(name: inv.name, argumentsJSON: inv.arguments)
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
    }
    try output.printMaxToolRoundsExceeded(max: maxToolRounds)
    return .hitToolRoundLimit
  }
}
