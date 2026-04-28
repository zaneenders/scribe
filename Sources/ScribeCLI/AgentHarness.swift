import Foundation
import OpenAPIRuntime

private enum AssistantStreamTone {
  case reasoning
  case content
}

/// Accumulates one assistant step from streamed chunks (content + parallel tool calls).
struct StreamedAssistantTurn {
  var text = ""
  var toolCalls: [Int: PartialToolCall] = [:]
  var finishReason: String?

  struct PartialToolCall {
    var id: String?
    var name: String?
    var arguments: String
  }

  mutating func apply(chunk: Components.Schemas.ChatCompletionChunk) {
    guard let choices = chunk.choices else { return }
    for choice in choices {
      if let fr = choice.finishReason {
        finishReason = fr
      }
      guard let delta = choice.delta else { continue }
      if let c = delta.content, !c.isEmpty {
        text += c
      }
      guard let deltas = delta.toolCalls else { continue }
      for td in deltas {
        let idx = td.index ?? 0
        var acc = toolCalls[idx] ?? PartialToolCall(id: nil, name: nil, arguments: "")
        if let id = td.id { acc.id = id }
        if let fn = td.function {
          if let n = fn.name { acc.name = n }
          if let a = fn.arguments { acc.arguments += a }
        }
        toolCalls[idx] = acc
      }
    }
  }

  func resolvedToolCalls() -> [(id: String, name: String, arguments: String)] {
    toolCalls.keys.sorted().compactMap { key in
      guard let t = toolCalls[key], let id = t.id, let name = t.name else { return nil }
      return (id, name, t.arguments)
    }
  }
}

struct AgentHarness {
  var client: Client
  var model: String
  var maxToolRounds: Int
  let tools = AgentTools.all()
  let runner = ToolRunner()

  private static func formatUsageCreative(_ u: Components.Schemas.CompletionUsage) -> String? {
    let p = u.promptTokens
    let c = u.completionTokens
    let t = u.totalTokens
    guard p != nil || c != nil || t != nil else { return nil }
    let inStr = p.map(String.init) ?? "—"
    let outStr = c.map(String.init) ?? "—"
    let sumStr = t.map(String.init) ?? "—"

    let innerVisible = "◆ \(inStr) in  ·  \(outStr) out  ·  \(sumStr) Σ ◆"
    let targetWidth = max(innerVisible.count + 10, 54)
    let sidePad = max(0, targetWidth - innerVisible.count)
    let padL = sidePad / 2
    let padR = sidePad - padL

    let bg = ANSI.usagePanelBg
    let rail = ANSI.usagePanelRailBg
    let m = ANSI.usagePanelMuted
    let ni = ANSI.usagePanelIn
    let no = ANSI.usagePanelOut
    let ns = ANSI.usagePanelSum
    let x = ANSI.reset

    let railRow = "  \(rail)\(m)" + String(repeating: "\u{00B7}", count: targetWidth) + "\(x)"
    let midInner =
      "\(m)◆ \(ni)\(inStr)\(m) in  ·  \(no)\(outStr)\(m) out  ·  \(ns)\(sumStr)\(m)\u{001B}[22m Σ ◆"
    let midRow =
      "  \(bg)" + String(repeating: " ", count: padL) + midInner + String(repeating: " ", count: padR) + "\(x)"

    return "\n\(railRow)\n\(midRow)\n\(railRow)"
  }

  func runModelTurn(messages: inout [Components.Schemas.ChatMessage]) async throws {
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
      var tone: AssistantStreamTone?
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
          try? FileHandle.standardError.write(
            contentsOf: Data(
              "\(ANSI.dim)(skipped one stream line: not valid completion JSON)\(ANSI.reset)\n".utf8
            ))
          continue
        }
        if let u = chunk.usage {
          lastUsage = u
        }
        for choice in chunk.choices ?? [] {
          guard let delta = choice.delta else { continue }
          for r in [delta.reasoningContent, delta.reasoning].compactMap({ $0 }).filter({ !$0.isEmpty }) {
            streamStarted = true
            if tone != .reasoning {
              try FileHandle.standardOutput.write(contentsOf: Data(ANSI.reset.utf8))
              if tone != nil { try FileHandle.standardOutput.write(contentsOf: Data("\n".utf8)) }
              try FileHandle.standardOutput.write(
                contentsOf: Data("\(ANSI.purple)scribe:\(ANSI.reset)\n".utf8))
              try FileHandle.standardOutput.write(contentsOf: Data("\(ANSI.thinking)  ".utf8))
              tone = .reasoning
            }
            try FileHandle.standardOutput.write(contentsOf: Data(r.utf8))
            try FileHandle.standardOutput.synchronize()
          }
          if let t = delta.content, !t.isEmpty {
            streamStarted = true
            if tone != .content {
              try FileHandle.standardOutput.write(contentsOf: Data(ANSI.reset.utf8))
              if tone != nil { try FileHandle.standardOutput.write(contentsOf: Data("\n".utf8)) }
              try FileHandle.standardOutput.write(
                contentsOf: Data("\(ANSI.purple)scribe:\(ANSI.reset)\n".utf8))
              try FileHandle.standardOutput.write(contentsOf: Data(ANSI.cyan.utf8))
              tone = .content
            }
            try FileHandle.standardOutput.write(contentsOf: Data(t.utf8))
            try FileHandle.standardOutput.synchronize()
          }
        }
        turn.apply(chunk: chunk)
      }
      if streamStarted {
        try FileHandle.standardOutput.write(contentsOf: Data("\(ANSI.reset)\n".utf8))
        try FileHandle.standardOutput.synchronize()
      } else if turn.text.isEmpty, turn.resolvedToolCalls().isEmpty {
        print(
          "\(ANSI.purple)scribe:\(ANSI.reset)\n\(ANSI.dim)(empty turn)\(ANSI.reset)"
        )
      }

      if let u = lastUsage, let usageLine = Self.formatUsageCreative(u) {
        print(usageLine)
      }

      let toolInvocations = turn.resolvedToolCalls()
      // Use a real empty string when there is no visible `content` delta. Reasoning/thinking
      // chunks are shown in the terminal but are not merged into `turn.text`; `content: nil`
      // encodes with no `content` key (`encodeIfPresent`), and some providers respond with
      // HTTP 400 "invalid message content type" for assistant rows that have `tool_calls`
      // but omit or null-out `content`.
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
        print()
        return
      }

      print(
        "\(ANSI.yellow)\(ANSI.bold)tool round \(round + 1)\(ANSI.reset) "
          + "\(ANSI.cyan)\(toolInvocations.map(\.name).joined(separator: ", "))\(ANSI.reset)"
      )

      for inv in toolInvocations {
        let output = await runner.run(name: inv.name, argumentsJSON: inv.arguments)
        let argSummary = ToolDisplay.argumentSummary(name: inv.name, argumentsJSON: inv.arguments)
        let head =
          "\(ANSI.yellow)▶ \(inv.name)\(ANSI.reset)"
          + (argSummary.map { " \(ANSI.dim)\($0)\(ANSI.reset)" } ?? "")
        print(head)
        for line in ToolDisplay.outputLines(name: inv.name, jsonOutput: output) {
          print("  \(line)")
        }
        print()
        let toolMsg = Components.Schemas.ChatMessage(
          role: .tool,
          content: output,
          name: nil,
          toolCalls: nil,
          toolCallId: inv.id
        )
        messages.append(toolMsg)
      }
    }
    print("\(ANSI.yellow)Stopped: max tool rounds (\(maxToolRounds)) exceeded.\(ANSI.reset)\n")
  }
}

/// Human-readable terminal formatting for JSON tool payloads (conversation history still receives raw JSON).
private enum ToolDisplay {
  private static let toolJSONDecoder: JSONDecoder = {
    let d = JSONDecoder()
    d.keyDecodingStrategy = .convertFromSnakeCase
    return d
  }()

  /// Arguments for `shell` / `read_file` / `write_file` / `edit_file` display (matches `ToolRunner` keys).
  private struct ShellInvocationArgs: Decodable {
    let command: String
    let cwd: String?
  }

  private struct PathInvocationArgs: Decodable {
    let path: String
  }

  /// Decoded tool result body (keys align with `ToolRunner` JSON); optional fields depend on tool.
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

  /// Short line parsed from tool arguments for the heading (e.g. shell command).
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
      guard let args = try? toolJSONDecoder.decode(PathInvocationArgs.self, from: data) else { return nil }
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

  /// Pretty-print for tool payloads that do not need custom line layout (unknown tools, missing fields).
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
