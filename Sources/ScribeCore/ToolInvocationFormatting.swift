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
