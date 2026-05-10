import Foundation
import ScribeCore

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
    let stdoutFile: String?
    let stderrFile: String?
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
      // Output is streamed to temp files on disk — the transcript just shows
      // the file paths so the human knows where results landed.  The LLM can
      // use `read_file` to fetch the contents when it needs them.
      var lines: [String] = []
      if let code = decoded.exitCode {
        lines.append("exit \(code)")
      }
      if let outFile = decoded.stdoutFile {
        let sizeStr = fileSizeString(outFile)
        lines.append("stdout → \(outFile)\(sizeStr)")
      }
      if let errFile = decoded.stderrFile {
        let sizeStr = fileSizeString(errFile)
        lines.append("stderr → \(errFile)\(sizeStr)")
      }
      return lines.isEmpty ? ["(no output)"] : lines

    case "read_file":
      // Show only a single summary line in the transcript — the full content lives in the
      // conversation history (visible to the model). Avoiding the (potentially thousands of)
      // wrapped content rows here keeps the transcript flatten/render path cheap right after
      // a big read.
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
      parts.append("\(ScribeUsageFormatting.groupingInt(bytes)) bytes")
    }
    if let total = decoded.totalLines {
      parts.append("\(ScribeUsageFormatting.groupingInt(total)) lines")
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

  /// Returns a human-readable file size like " (1.2 KB)" or "" if the file can't be stat'd.
  private static func fileSizeString(_ path: String) -> String {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
      let size = attrs[.size] as? Int64
    else { return "" }
    return " (\(ScribeUsageFormatting.groupingInt(Int(size))) bytes)"
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
