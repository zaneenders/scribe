import Foundation

struct ReadFileToolResult: Encodable, Sendable {
  let ok = true
  let path: String
  let content: String
  let bytes: Int
  let totalLines: Int
  let startLine: Int
  let endLine: Int
  let truncated: Bool
}

public struct ReadFileTool: ScribeTool {
  public static var name: String { "read_file" }

  public init() {}

  /// Default cap when the model omits `limit` — picked to keep tool messages bounded so a
  /// single read on a multi-megabyte file does not balloon the conversation history (every
  /// subsequent model turn re-uploads the full transcript).
  static let defaultLineLimit = 2000

  public func run(arguments: String) async throws -> Encodable {
    let obj = try ToolArgumentParsing.parseJSONObject(arguments)
    let path = try ToolArgumentParsing.string(obj["path"], field: "path")
    let offset = ToolArgumentParsing.optionalInt(obj["offset"])
    let limit = ToolArgumentParsing.optionalInt(obj["limit"])
    let result = try Self.readFile(path: path, offset: offset, limit: limit)
    return ReadFileToolResult(
      path: result.absolutePath,
      content: result.content,
      bytes: result.totalBytes,
      totalLines: result.totalLines,
      startLine: result.startLine,
      endLine: result.endLine,
      truncated: result.truncated
    )
  }

  struct ReadFileResult {
    let absolutePath: String
    let content: String
    let totalBytes: Int
    let totalLines: Int
    let startLine: Int
    let endLine: Int
    let truncated: Bool
  }

  /// Reads a UTF-8 file with optional **line-based** pagination.
  ///
  /// - `offset`: 1-indexed start line. Values `nil`, `0`, or `1` start from the top. Values
  ///   greater than `total_lines` produce an empty `content` slice (still `ok=true`) so the
  ///   model can detect end-of-file without erroring out.
  /// - `limit`: maximum number of lines to return; defaults to ``defaultLineLimit``.
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
      resolvedLimit = defaultLineLimit
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
}
