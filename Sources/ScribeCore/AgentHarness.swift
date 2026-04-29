import Foundation
import OpenAPIRuntime
import ScribeLLM

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

  public func runModelTurn(messages: inout [Components.Schemas.ChatMessage]) async throws
    -> ModelTurnOutcome
  {
    for round in 0..<maxToolRounds {
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
      let response = try await client.createChatCompletion(body: .json(requestBody))
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
      for try await sse in sseStream {
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
          try output.printSkippedUnreadableStreamLine()
          continue
        }
        if let u = chunk.usage {
          lastUsage = u
        }
        for choice in chunk.choices ?? [] {
          guard let delta = choice.delta else { continue }
          for r in [delta.reasoningContent, delta.reasoning].compactMap({ $0 }).filter({ !$0.isEmpty }) {
            streamStarted = true
            if case .some(.reasoning) = streamSection {
            } else {
              try output.enterAssistantStreamSection(.reasoning, previous: streamSection)
              streamSection = .reasoning
            }
            try output.appendAssistantStreamText(.reasoning, text: r)
          }
          if let t = delta.content, !t.isEmpty {
            streamStarted = true
            if case .some(.answer) = streamSection {
            } else {
              try output.enterAssistantStreamSection(.answer, previous: streamSection)
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
        try output.printEmptyAssistantTurn()
      }

      if let u = lastUsage {
        try output.emitUsage(
          promptTokens: u.promptTokens,
          completionTokens: u.completionTokens,
          totalTokens: u.totalTokens
        )
      }

      let toolInvocations = turn.resolvedToolCalls()
      let assistantText = turn.text.isEmpty ? "" : turn.text
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
        toolCallId: nil
      )
      messages.append(assistantMessage)

      if toolInvocations.isEmpty {
        try output.printBlankLine()
        return .completed
      }

      try output.printToolRoundHeader(round: round + 1, toolNames: toolInvocations.map(\.name))

      for inv in toolInvocations {
        let jsonOutput = await runner.run(name: inv.name, argumentsJSON: inv.arguments)
        let argSummary = ToolDisplay.argumentSummary(name: inv.name, argumentsJSON: inv.arguments)
        let lines = ToolDisplay.outputLines(name: inv.name, jsonOutput: jsonOutput)
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

/// Human-readable transcript lines for tool JSON (conversation history still receives raw JSON).
private enum ToolDisplay {
  private static let toolJSONDecoder: JSONDecoder = {
    let d = JSONDecoder()
    d.keyDecodingStrategy = .convertFromSnakeCase
    return d
  }()

  private struct ShellInvocationArgs: Decodable {
    let command: String
    let cwd: String?
  }

  private struct PathInvocationArgs: Decodable {
    let path: String
  }

  private struct ToolResultBody: Decodable {
    let ok: Bool
    let error: String?
    let exitCode: Int?
    let stdout: String?
    let stderr: String?
    let content: String?
    let written: Bool?
    let replaced: Bool?
  }

  static func argumentSummary(name: String, argumentsJSON: String) -> String? {
    let trimmed = argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = trimmed.data(using: .utf8) else { return nil }
    switch name {
    case "shell":
      guard let args = try? toolJSONDecoder.decode(ShellInvocationArgs.self, from: data) else { return nil }
      if let cwd = args.cwd?.trimmingCharacters(in: .whitespacesAndNewlines), !cwd.isEmpty {
        return "\(args.command)  (cwd: \(cwd))"
      }
      return args.command
    case "read_file", "write_file", "edit_file":
      guard let args = try? toolJSONDecoder.decode(PathInvocationArgs.self, from: data) else {
        return nil
      }
      return args.path
    default:
      return nil
    }
  }

  static func outputLines(name: String, jsonOutput: String) -> [String] {
    guard let data = jsonOutput.data(using: .utf8),
      let decoded = try? toolJSONDecoder.decode(ToolResultBody.self, from: data)
    else {
      return [jsonOutput]
    }

    if !decoded.ok {
      return ["error: \(decoded.error ?? "unknown error")"]
    }

    switch name {
    case "shell":
      var lines: [String] = []
      if let code = decoded.exitCode {
        lines.append("exit \(code)")
      }
      let out = decoded.stdout ?? ""
      let err = decoded.stderr ?? ""
      if !out.isEmpty {
        lines.append("stdout:")
        lines += out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
      }
      if !err.isEmpty {
        lines.append("stderr:")
        lines += err.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
      }
      return lines.isEmpty ? ["(no output)"] : lines

    case "read_file":
      return truncatedFileLines(decoded.content ?? "")

    case "edit_file":
      return ["replaced; result preview:"] + truncatedFileLines(decoded.content ?? "")

    case "write_file":
      return ["written"]

    default:
      return fallbackPrettyLines(jsonOutput) ?? [jsonOutput]
    }
  }

  private static func truncatedFileLines(_ content: String) -> [String] {
    let maxLines = 48
    let parts = content.split(separator: "\n", omittingEmptySubsequences: false)
    var lines = Array(parts.prefix(maxLines).map(String.init))
    if parts.count > maxLines {
      lines.append("… (\(parts.count - maxLines) more lines not shown)")
    }
    return lines.isEmpty ? ["(empty file)"] : lines
  }

  private static func fallbackPrettyLines(_ jsonOutput: String) -> [String]? {
    guard let data = jsonOutput.data(using: .utf8),
      let obj = try? JSONSerialization.jsonObject(with: data),
      JSONSerialization.isValidJSONObject(obj),
      let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
      let s = String(data: out, encoding: .utf8),
      s.count <= 12_000
    else { return nil }
    return s.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
  }
}
