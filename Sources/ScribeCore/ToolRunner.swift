import Foundation

public struct ToolRunner: Sendable {
  public init() {}

  public struct Outcome: Sendable {
    public let text: String

    public init(text: String) {
      self.text = text
    }
  }

  /// Entry point for the OpenAPI tool loop.
  public func run(name: String, argumentsJSON: String) async -> String {
    await Self._run(name: name, arguments: argumentsJSON).text
  }

  private static func _run(name: String, arguments: String) async -> Outcome {
    do {
      let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
      let obj: [String: Any]
      if trimmed.isEmpty {
        obj = [:]
      } else {
        let any = try JSONSerialization.jsonObject(with: Data(arguments.utf8), options: [])
        obj = (any as? [String: Any]) ?? [:]
      }

      switch name {
      case "shell":
        let command = try string(obj["command"], field: "command")
        var cwd: String? = optionalString(obj["cwd"])
        if let c = cwd, c.isEmpty { cwd = nil }
        let r = try await Shell.run(command: command, cwd: cwd)
        return .init(
          text: jsonOk([
            "exit_code": r.exitCodeForJSON,
            "stdout": r.stdout,
            "stderr": r.stderr,
          ]))

      case "read_file":
        let path = try string(obj["path"], field: "path")
        let offset = optionalInt(obj["offset"])
        let limit = optionalInt(obj["limit"])
        let result = try readFile(path: path, offset: offset, limit: limit)
        return .init(
          text: jsonOk([
            "path": result.absolutePath,
            "content": result.content,
            "bytes": result.totalBytes,
            "total_lines": result.totalLines,
            "start_line": result.startLine,
            "end_line": result.endLine,
            "truncated": result.truncated,
          ] as [String: Any]))

      case "write_file":
        let path = try string(obj["path"], field: "path")
        let content = try string(obj["content"], field: "content")
        try writeFile(path: path, content: content)
        return .init(text: jsonOk(["written": true]))

      case "edit_file":
        let path = try string(obj["path"], field: "path")
        let oldS = try string(obj["old_string"], field: "old_string")
        let newS = try string(obj["new_string"], field: "new_string")
        let updated = try editFile(path: path, old: oldS, new: newS)
        return .init(text: jsonOk(["replaced": true, "content": updated]))

      default:
        return .init(text: jsonError("unknown tool \(name)"))
      }
    } catch {
      return .init(text: jsonError(String(describing: error)))
    }
  }

  /// Result of a `read_file` invocation. Pagination is **line-based and 1-indexed** so the
  /// model can iterate over a file with `offset = previous end_line + 1` after each call:
  /// see ``readFile(path:offset:limit:)`` for the slicing rules.
  ///
  /// `totalBytes` reports the byte count of the *whole* file (not just the slice) so the
  /// model can decide whether more pages are worth fetching, and `truncated` is `true` when
  /// `limit` cut the slice short of `total_lines`.
  struct ReadFileResult {
    let absolutePath: String
    let content: String
    let totalBytes: Int
    let totalLines: Int
    let startLine: Int
    let endLine: Int
    let truncated: Bool
  }

  /// Default cap when the model omits `limit` — picked to keep tool messages bounded so a
  /// single read on a multi-megabyte file does not balloon the conversation history (every
  /// subsequent model turn re-uploads the full transcript).
  static let readFileDefaultLineLimit = 2000

  /// Reads a UTF-8 file with optional **line-based** pagination.
  ///
  /// - `offset`: 1-indexed start line. Values `nil`, `0`, or `1` start from the top. Values
  ///   greater than `total_lines` produce an empty `content` slice (still `ok=true`) so the
  ///   model can detect end-of-file without erroring out.
  /// - `limit`: maximum number of lines to return; defaults to ``readFileDefaultLineLimit``.
  ///   Pass `0` (or any non-positive value) to mean "no cap" and read to end of file.
  ///
  /// `start_line` and `end_line` in the returned result are inclusive 1-indexed line numbers
  /// within the original file; `end_line == start_line - 1` indicates an empty slice.
  private static func readFile(
    path: String,
    offset: Int?,
    limit: Int?
  ) throws -> ReadFileResult {
    let fp = try PathResolution.resolve(reading: path)
    let s = PathResolution.fileSystemPath(fp)
    let text = try String(contentsOfFile: s, encoding: .utf8)
    let totalBytes = text.utf8.count

    // `omittingEmptySubsequences: false` preserves trailing empty line for `"foo\n"` so
    // counts match what a user sees in `wc -l + 1`.
    let parts = text.split(separator: "\n", omittingEmptySubsequences: false)
    let totalLines = parts.count

    let startIndex = max(0, (offset ?? 1) - 1)
    let resolvedLimit: Int
    if let limit, limit > 0 {
      resolvedLimit = limit
    } else if limit == nil {
      resolvedLimit = readFileDefaultLineLimit
    } else {
      // Explicit `0` (or negative) — treat as "no cap".
      resolvedLimit = totalLines
    }

    if startIndex >= totalLines {
      return ReadFileResult(
        absolutePath: s,
        content: "",
        totalBytes: totalBytes,
        totalLines: totalLines,
        startLine: totalLines + 1,
        endLine: totalLines,
        truncated: false
      )
    }

    let endIndex = min(totalLines, startIndex + resolvedLimit)
    let slice = parts[startIndex..<endIndex].joined(separator: "\n")
    return ReadFileResult(
      absolutePath: s,
      content: slice,
      totalBytes: totalBytes,
      totalLines: totalLines,
      startLine: startIndex + 1,
      endLine: endIndex,
      truncated: endIndex < totalLines
    )
  }

  /// Convenience for callers that need full file contents (e.g. ``editFile`` matching).
  /// Equivalent to `readFile(path:offset:limit:)` with no slicing — all lines are returned.
  private static func readFileWhole(path: String) throws -> String {
    let fp = try PathResolution.resolve(reading: path)
    let s = PathResolution.fileSystemPath(fp)
    return try String(contentsOfFile: s, encoding: .utf8)
  }

  private static func requireParentDirectoryForWrite(filesystemPath: String, userPath: String) throws {
    let parent = URL(fileURLWithPath: filesystemPath).deletingLastPathComponent()
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDir), isDir.boolValue
    else {
      throw PathResolution.PathError(
        description: "parent directory does not exist for write: \(userPath)")
    }
  }

  private static func writeFile(path: String, content: String) throws {
    let fp = try PathResolution.resolve(writing: path)
    let s = PathResolution.fileSystemPath(fp)
    try requireParentDirectoryForWrite(filesystemPath: s, userPath: path)
    try content.write(toFile: s, atomically: true, encoding: .utf8)
  }

  private static func editFile(path: String, old: String, new: String) throws -> String {
    var text = try readFileWhole(path: path)
    if old.isEmpty { throw PathResolution.PathError(description: "old_string must not be empty for edit_file") }
    let n = numberOfNonOverlappingOccurrences(in: text, of: old)
    guard n == 1 else {
      if n == 0 {
        throw PathResolution.PathError(description: "old_string not found in file \(path)")
      }
      throw PathResolution.PathError(
        description: "old_string must be unique; found \(n) matches in \(path)"
      )
    }
    text = text.replacingOccurrences(of: old, with: new, options: [], range: nil)
    let fp = try PathResolution.resolve(writing: path)
    let s = PathResolution.fileSystemPath(fp)
    try requireParentDirectoryForWrite(filesystemPath: s, userPath: path)
    try text.write(toFile: s, atomically: true, encoding: .utf8)
    return text
  }

  private static func string(_ v: Any?, field: String) throws -> String {
    guard let v, let s = v as? String, !s.isEmpty else {
      throw PathResolution.PathError(description: "missing or empty field \(field)")
    }
    return s
  }

  private static func optionalString(_ v: Any?) -> String? {
    (v as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Accepts JSON numbers (`Int` / `Double` after `JSONSerialization`) and decimal strings
  /// (`"100"`); returns `nil` for missing, empty, or unparseable values so the caller can
  /// fall back to a default.
  private static func optionalInt(_ v: Any?) -> Int? {
    if let n = v as? Int { return n }
    if let n = v as? Double { return Int(n) }
    if let s = (v as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
      return Int(s)
    }
    return nil
  }

  private static func numberOfNonOverlappingOccurrences(in haystack: String, of needle: String) -> Int {
    if needle.isEmpty { return 0 }
    var count = 0
    var range = haystack.startIndex..<haystack.endIndex
    while let r = haystack.range(of: needle, range: range) {
      count += 1
      range = r.upperBound..<haystack.endIndex
    }
    return count
  }

  private static let jsonSerializationFallback =
    "{\"ok\":false,\"error\":\"tool result could not be encoded as JSON\"}"

  private static func jsonError(_ text: String) -> String {
    (try? jsonString(["ok": false, "error": text] as [String: Any])) ?? jsonSerializationFallback
  }

  private static func jsonOk(_ o: [String: Any]) -> String {
    var m = o
    m["ok"] = true
    return (try? jsonString(m)) ?? jsonSerializationFallback
  }

  private static func jsonString(_ o: [String: Any]) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: o, options: [])
    return String(data: data, encoding: .utf8) ?? "{}"
  }
}
