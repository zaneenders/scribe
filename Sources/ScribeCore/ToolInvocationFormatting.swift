import Foundation

/// Human-readable transcript lines for tool JSON (conversation history still receives raw JSON).
public enum ToolInvocationFormatting {

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
    let bytes: Int?
    let totalLines: Int?
    let startLine: Int?
    let endLine: Int?
    let truncated: Bool?
    let path: String?
  }

  public static func argumentSummary(name: String, argumentsJSON: String) -> String? {
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

  /// Structured `key=value key=value` snippet describing a `read_file` result, intended for
  /// embedding in a `Logger` line (the harness wraps it with `event=agent.tool.read_file`).
  /// Returns `decode_failed=true` when the JSON cannot be parsed so the log still records
  /// that something happened.
  public static func readFileLogSummary(jsonOutput: String) -> String {
    guard let data = jsonOutput.data(using: .utf8),
      let decoded = try? toolJSONDecoder.decode(ToolResultBody.self, from: data)
    else {
      return "decode_failed=true output_chars=\(jsonOutput.count)"
    }
    if !decoded.ok {
      let err = decoded.error?.replacingOccurrences(of: "\"", with: "\\\"") ?? "unknown"
      return "ok=false err=\"\(err)\""
    }
    let path = decoded.path?.replacingOccurrences(of: "\"", with: "\\\"") ?? ""
    let bytes = decoded.bytes ?? 0
    let totalLines = decoded.totalLines ?? 0
    let startLine = decoded.startLine ?? 1
    let endLine = decoded.endLine ?? 0
    let returnedLines = max(0, endLine - startLine + 1)
    let truncated = decoded.truncated ?? false
    let contentChars = decoded.content?.count ?? 0
    return
      """
      ok=true \
      path="\(path)" \
      bytes=\(bytes) \
      total_lines=\(totalLines) \
      start_line=\(startLine) \
      end_line=\(endLine) \
      returned_lines=\(returnedLines) \
      content_chars=\(contentChars) \
      truncated=\(truncated)
      """
  }

  public static func outputLines(name: String, jsonOutput: String) -> [String] {
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
      // Cap each stream at `shellTranscriptStreamLineCap` lines in the transcript display.
      // The full stdout/stderr is always preserved in the conversation history sent to the
      // model — this only affects the rendered scrollback. Without this cap, a single
      // command that prints (e.g.) 114 KB of output added 1500+ wrapped rows to the
      // transcript and made every subsequent render 100+ ms — long enough to perceptibly
      // delay keystrokes processed on the same actor.
      var lines: [String] = []
      if let code = decoded.exitCode {
        lines.append("exit \(code)")
      }
      let out = decoded.stdout ?? ""
      let err = decoded.stderr ?? ""
      if !out.isEmpty {
        lines.append("stdout:")
        lines += truncatedStreamLines(out)
      }
      if !err.isEmpty {
        lines.append("stderr:")
        lines += truncatedStreamLines(err)
      }
      return lines.isEmpty ? ["(no output)"] : lines

    case "read_file":
      // Show only a single summary line in the transcript — the full content lives in the
      // conversation history (visible to the model) and in the structured log line emitted
      // from `AgentHarness`. Avoiding the (potentially thousands of) wrapped content rows
      // here keeps the transcript flatten/render path cheap right after a big read.
      return [readFileSummaryLine(decoded: decoded)]

    case "edit_file":
      return ["replaced"]

    case "write_file":
      return ["written"]

    default:
      return fallbackPrettyLines(jsonOutput) ?? [jsonOutput]
    }
  }

  /// Compact one-line summary for a `read_file` result: total file size, full line count, the
  /// inclusive line range actually returned, and a `truncated` hint when the slice was capped
  /// by `limit`. Falls back to "(no content)" when the structured fields are absent.
  private static func readFileSummaryLine(decoded: ToolResultBody) -> String {
    var parts: [String] = []
    if let bytes = decoded.bytes {
      parts.append("\(formatGroupedInt(bytes)) bytes")
    }
    if let total = decoded.totalLines {
      parts.append("\(formatGroupedInt(total)) lines")
    }
    if let start = decoded.startLine, let end = decoded.endLine {
      if end >= start {
        parts.append("returned \(start)–\(end)")
      } else {
        parts.append("returned 0 lines (offset past end)")
      }
    }
    if decoded.truncated == true {
      parts.append("truncated by limit")
    }
    if parts.isEmpty {
      let count = decoded.content?.count ?? 0
      return count == 0 ? "(no content)" : "\(count) chars"
    }
    return parts.joined(separator: "  ")
  }

  /// Maximum lines of a single shell stream (stdout or stderr) shown in the transcript.
  /// Picked to keep a single command's display cost bounded while still showing enough
  /// context for a human skim; the full text remains in the conversation history.
  internal static let shellTranscriptStreamLineCap = 200
  internal static let shellTranscriptStreamHeadLines = 120
  internal static let shellTranscriptStreamTailLines = 60

  /// Splits `text` on newlines and, if it exceeds the cap, returns the head + a truncation
  /// marker + the tail. Keeping head and tail (instead of just head) means error messages
  /// at the end of long output (compiler errors, Python tracebacks, etc.) are still visible
  /// without dumping thousands of intermediate lines.
  private static func truncatedStreamLines(_ text: String) -> [String] {
    let split = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let count = split.count
    if count <= shellTranscriptStreamLineCap {
      return split
    }
    let hidden = count - shellTranscriptStreamHeadLines - shellTranscriptStreamTailLines
    let head = Array(split.prefix(shellTranscriptStreamHeadLines))
    let tail = Array(split.suffix(shellTranscriptStreamTailLines))
    let marker =
      "… (\(formatGroupedInt(hidden)) more line\(hidden == 1 ? "" : "s") hidden — full output preserved in conversation) …"
    return head + [marker] + tail
  }

  /// Renders `1234567` as `1,234,567` for human-readable summaries — kept inline rather than
  /// pulling in `NumberFormatter` (which is slower and not `Sendable`).
  private static func formatGroupedInt(_ n: Int) -> String {
    let s = String(abs(n))
    var out = ""
    var counter = 0
    for ch in s.reversed() {
      if counter != 0, counter % 3 == 0 { out.append(",") }
      out.append(ch)
      counter += 1
    }
    return (n < 0 ? "-" : "") + String(out.reversed())
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
