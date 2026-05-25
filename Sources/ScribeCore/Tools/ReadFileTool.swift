import SystemPackage
import Foundation
import Logging
import _NIOFileSystem

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

struct ReadFileImageResult: Encodable, AttachableToolResult, Sendable {
  let ok = true
  let path: String
  let isImage = true
  let mimeType: String
  let base64: String
  let bytes: Int

  var toolAttachments: [ToolAttachment] {
    [ToolAttachment(mimeType: mimeType, base64: base64, sourcePath: path)]
  }
}

struct ReadFileImageTooLargeResult: Encodable, WarnableToolResult, Sendable {
  let ok = false
  let path: String
  let error: String

  var toolWarnings: [String] { [error] }
}

public struct ReadFileTool: ScribeTool {
  public static var name: String { "read_file" }
  public static var description: String {
    "Read a UTF-8 file at the given path (relative paths resolve against the process cwd). "
      + "Supports line-based pagination via `offset` and `limit` so very large files can be "
      + "fetched in sections without bloating the conversation history. The result includes "
      + "`bytes`, `total_lines`, `start_line`, `end_line`, and `truncated` so you can decide "
      + "whether to request another page (`offset = previous end_line + 1`). "
      + "Image files are automatically detected by their contents (magic bytes) and returned "
      + "as base64-encoded data so the model can view them."
  }
  public static var parameters: [ScribeToolParameter] {
    [
      ScribeToolParameter(
        name: "path", type: .string,
        description: "Filesystem path (relative paths resolve against the process cwd).",
        required: true),
      ScribeToolParameter(
        name: "offset", type: .integer,
        description:
          "1-indexed line number to start reading from. Omit (or pass 1) to start at the top. "
          + "Use the previous call's `end_line + 1` to read the next page of a large file.",
        required: false),
      ScribeToolParameter(
        name: "limit", type: .integer,
        description:
          "Maximum number of lines to return (default 2000). Pass a smaller value when only a "
          + "section is needed; pass `0` to read to end of file. Response includes `total_lines`, "
          + "`start_line`, `end_line`, and `truncated` so you can tell whether to fetch another page.",
        required: false),
    ]
  }
  public static var promptHint: String? {
    "For `read_file`, prefer paginating large files: pass `offset` (1-indexed start line) "
      + "and `limit` (max lines, default 2000) and use the returned `end_line` + 1 as the "
      + "next `offset` if `truncated` is true. This keeps the conversation history small."
  }

  public init() {}

  static let defaultLineLimit = 2000

  public func run(arguments: String, workingDirectory: FilePath, logger: Logger) async throws -> Encodable {
    let obj = try ToolArgumentParsing.parseJSONObject(arguments)
    let path = try ToolArgumentParsing.string(obj["path"], field: "path")
    let offset = ToolArgumentParsing.optionalInt(obj["offset"])
    let limit = ToolArgumentParsing.optionalInt(obj["limit"])

    let fp = try PathResolution.resolve(reading: path, cwd: workingDirectory)
    let s = fp.string

    if ImageSupport.isImageFile(path: s) {
      let maxImageBytes = 5 * 1024 * 1024
      if let info = try? await FileSystem.shared.info(forFileAt: fp),
        info.size > maxImageBytes
      {
        let name = URL(fileURLWithPath: s).lastPathComponent
        let msg = "\(name) is too large to attach (\(info.size / (1024 * 1024)) MB, limit 5 MB)"
        logger.warning(
          "agent.tool.read_file.image.too-large",
          metadata: ["path": "\(s)", "bytes": "\(info.size)", "limit_bytes": "\(maxImageBytes)"])
        return ReadFileImageTooLargeResult(path: s, error: msg)
      }
      let result = try await Self.readImage(path: s)
      logger.debug(
        "agent.tool.read_file.image",
        metadata: [
          "ok": "true",
          "path": "\(result.path.replacingOccurrences(of: "\"", with: "\\\""))",
          "mime_type": "\(result.mimeType)",
          "bytes": "\(result.bytes)",
        ])
      return result
    }

    let result = try Self.readFile(path: path, offset: offset, limit: limit, workingDirectory: workingDirectory)
    let returnedLines = max(0, result.endLine - result.startLine + 1)
    logger.debug(
      "agent.tool.read_file",
      metadata: [
        "ok": "true",
        "path": "\(result.absolutePath.replacingOccurrences(of: "\"", with: "\\\""))",
        "bytes": "\(result.totalBytes)",
        "total_lines": "\(result.totalLines)",
        "start_line": "\(result.startLine)",
        "end_line": "\(result.endLine)",
        "returned_lines": "\(returnedLines)",
        "content_chars": "\(result.content.count)",
        "truncated": "\(result.truncated)",
      ])
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

  private static func readFile(
    path: String,
    offset: Int?,
    limit: Int?,
    workingDirectory: FilePath
  ) throws -> ReadFileResult {
    let fp = try PathResolution.resolve(reading: path, cwd: workingDirectory)
    let s = fp.string
    let text = try String(contentsOfFile: s, encoding: .utf8)
    let totalBytes = text.utf8.count

    let parts = text.split(separator: "\n", omittingEmptySubsequences: false)
    let totalLines = parts.count

    let startIndex = max(0, (offset ?? 1) - 1)
    let resolvedLimit: Int
    if let limit, limit > 0 {
      resolvedLimit = limit
    } else if limit == nil {
      resolvedLimit = defaultLineLimit
    } else {

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

  private static func readImage(path: String) async throws -> ReadFileImageResult {
    let (mimeType, base64, bytes) = try await Task {
      try ImageSupport.base64ImageData(from: path)
    }.value
    return ReadFileImageResult(path: path, mimeType: mimeType, base64: base64, bytes: bytes)
  }
}
