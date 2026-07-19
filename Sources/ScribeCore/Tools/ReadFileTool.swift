import Foundation
import Logging
import SystemPackage
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
  let truncationReason: String?
  let contentBytes: Int
  let contentCharacters: Int
  let maxContentBytes: Int
  let maxContentCharacters: Int
  let byteOffset: Int?
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

  var attachmentToolResultText: String? {
    let payload: [String: Any] = [
      "ok": true,
      "path": path,
      "is_image": true,
      "mime_type": mimeType,
      "bytes": bytes,
      "attached": true,
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    else { return nil }
    return String(decoding: data, as: UTF8.self)
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
      + "whether to request another page (`offset = previous end_line + 1`). Text output is also "
      + "capped at 64 KiB and 64,000 characters, including when `limit` is `0`. "
      + "When the cap lands inside a long line the result includes `byte_offset`; pass it back "
      + "as the `byte_offset` parameter on the next call to continue reading from that byte position. "
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
          + "section is needed; pass `0` to remove the line cap. The hard 64 KiB / 64,000-character "
          + "content cap always applies. Response includes `total_lines`, `start_line`, `end_line`, "
          + "`truncated`, and `truncation_reason` so you can tell whether to fetch another page.",
        required: false),
      ScribeToolParameter(
        name: "byte_offset", type: .integer,
        description:
          "Byte offset into the file to start reading from. Use when a previous result included "
          + "a `byte_offset` field (the cap hit inside a long line). When provided the read skips "
          + "to this byte position and the `offset` parameter is ignored.",
        required: false),
    ]
  }
  public static var promptHint: String? {
    "For `read_file`, prefer paginating large files: pass `offset` (1-indexed start line) "
      + "and `limit` (max lines, default 2000) and use the returned `end_line` + 1 as the "
      + "next `offset` if `truncated` is true. If the result has a `byte_offset` field the cap "
      + "landed inside a long line; pass it as the `byte_offset` parameter on the next call "
      + "to continue reading (do not pass `offset` in that case). "
      + "This keeps the conversation history small."
  }

  public init() {}

  static let defaultLineLimit = 2000
  static let maxContentBytes = 64 * 1024
  static let maxContentCharacters = 64_000

  public func run(arguments: String, workingDirectory: FilePath, logger: Logger) async throws -> Encodable {
    let obj = try ToolArgumentParsing.parseJSONObject(arguments)
    let path = try ToolArgumentParsing.string(obj["path"], field: "path")
    let offset = ToolArgumentParsing.optionalInt(obj["offset"])
    let limit = ToolArgumentParsing.optionalInt(obj["limit"])
    let byteOffset = ToolArgumentParsing.optionalInt(obj["byte_offset"])

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

    let result = try Self.readFile(path: path, offset: offset, limit: limit, byteOffset: byteOffset, workingDirectory: workingDirectory)
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
        "content_bytes": "\(result.content.utf8.count)",
        "content_chars": "\(result.content.count)",
        "truncated": "\(result.truncated)",
        "truncation_reason": "\(result.truncationReason ?? "nil")",
        "byte_offset": "\(result.byteOffset.map(String.init) ?? "nil")",
      ])
    return ReadFileToolResult(
      path: result.absolutePath,
      content: result.content,
      bytes: result.totalBytes,
      totalLines: result.totalLines,
      startLine: result.startLine,
      endLine: result.endLine,
      truncated: result.truncated,
      truncationReason: result.truncationReason,
      contentBytes: result.content.utf8.count,
      contentCharacters: result.content.count,
      maxContentBytes: Self.maxContentBytes,
      maxContentCharacters: Self.maxContentCharacters,
      byteOffset: result.byteOffset
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
    let truncationReason: String?
    let byteOffset: Int?
  }

  private static func readFile(
    path: String,
    offset: Int?,
    limit: Int?,
    byteOffset: Int?,
    workingDirectory: FilePath
  ) throws -> ReadFileResult {
    let fp = try PathResolution.resolve(reading: path, cwd: workingDirectory)
    let s = fp.string
    let text = try String(contentsOfFile: s, encoding: .utf8)
    let totalBytes = text.utf8.count

    // When byte_offset is provided, skip to that byte position in the file.
    let effectiveText: String
    let byteOffsetBase: Int  // byte offset in original file where effectiveText starts
    if let bo = byteOffset, bo > 0, bo < text.utf8.count {
      guard let utf8Idx = text.utf8.index(text.utf8.startIndex, offsetBy: bo, limitedBy: text.utf8.endIndex)
      else {
        return ReadFileResult(
          absolutePath: s, content: "", totalBytes: totalBytes, totalLines: 0,
          startLine: 0, endLine: 0, truncated: false, truncationReason: nil, byteOffset: nil)
      }
      guard let strIdx = String.Index(utf8Idx, within: text) else {
        return ReadFileResult(
          absolutePath: s, content: "", totalBytes: totalBytes, totalLines: 0,
          startLine: 0, endLine: 0, truncated: false, truncationReason: nil, byteOffset: nil)
      }
      effectiveText = String(text[strIdx...])
      byteOffsetBase = bo
    } else {
      effectiveText = text
      byteOffsetBase = 0
    }

    let parts = effectiveText.split(separator: "\n", omittingEmptySubsequences: false)
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
        truncated: false,
        truncationReason: nil,
        byteOffset: nil
      )
    }

    let endIndex = min(totalLines, startIndex + resolvedLimit)
    let requestedSlice = parts[startIndex..<endIndex].joined(separator: "\n")

    // Compute the byte offset in the *original* file where requestedSlice starts.
    // Each part's byte length + 1 for its \n separator (lines before startIndex).
    let sliceStartByteOffset: Int = {
      var off = byteOffsetBase
      for i in 0..<startIndex {
        off += parts[i].utf8.count + 1  // +1 for the \n that was split away
      }
      return off
    }()

    let bounded = boundedContent(requestedSlice)

    // Count lines in the bounded (possibly backtracked) content.
    let returnedLineCount = bounded.content.reduce(into: 1) { count, character in
      if character == "\n" { count += 1 }
    }

    // Determine whether the bounded content ends at a clean line boundary.
    let endsAtNewline = bounded.content.isEmpty || bounded.content.last == "\n"

    let returnedEndLine: Int
    let nextByteOffset: Int?

    if bounded.reason != nil && !endsAtNewline {
      // Content cap landed mid-line and we couldn't backtrack to a newline
      // (single long line or the cap landed in the first line with no prior newline).
      // Report only complete lines and provide a byte offset for continuation.
      returnedEndLine = startIndex + max(0, returnedLineCount - 1)
      nextByteOffset = sliceStartByteOffset + bounded.content.utf8.count
    } else {
      returnedEndLine = min(endIndex, startIndex + returnedLineCount)
      nextByteOffset = nil
    }

    let lineTruncated = (bounded.reason == nil) && endIndex < totalLines
    let truncated = bounded.reason != nil || lineTruncated
    let truncationReason = bounded.reason ?? (lineTruncated ? "line_limit" : nil)

    return ReadFileResult(
      absolutePath: s,
      content: bounded.content,
      totalBytes: totalBytes,
      totalLines: totalLines,
      startLine: startIndex + 1,
      endLine: returnedEndLine,
      truncated: truncated,
      truncationReason: truncationReason,
      byteOffset: nextByteOffset
    )
  }

  private static func boundedContent(_ content: String) -> (content: String, reason: String?) {
    guard content.count > maxContentCharacters || content.utf8.count > maxContentBytes else {
      return (content, nil)
    }

    var end = content.startIndex
    var bytes = 0
    var characters = 0
    while end < content.endIndex, characters < maxContentCharacters {
      let next = content.index(after: end)
      let characterBytes = content[end..<next].utf8.count
      guard bytes + characterBytes <= maxContentBytes else { break }
      bytes += characterBytes
      characters += 1
      end = next
    }

    // Backtrack to the last newline so we always end at a clean line boundary.
    // The slice content[..<end] should either hit EOF or end with \n.
    if end < content.endIndex {
      let lastIncluded = content.index(before: end)
      if content[lastIncluded] != "\n" {
        var backtrack = lastIncluded
        while backtrack > content.startIndex {
          backtrack = content.index(before: backtrack)
          if content[backtrack] == "\n" {
            // Include the newline in the returned content
            end = content.index(after: backtrack)
            break
          }
        }
        // If no newline found, keep the original truncation point (mid-line)
      }
      // else: last included char is already \n — clean boundary, nothing to do
    }
    // else: end == content.endIndex — consumed everything, no backtracking needed

    let reason: String
    if characters == maxContentCharacters && bytes == maxContentBytes {
      reason = "byte_and_character_limit"
    } else if characters == maxContentCharacters {
      reason = "character_limit"
    } else {
      reason = "byte_limit"
    }
    return (String(content[..<end]), reason)
  }

  private static func readImage(path: String) async throws -> ReadFileImageResult {
    let (mimeType, base64, bytes) = try await Task {
      try ImageSupport.base64ImageData(from: path)
    }.value
    return ReadFileImageResult(path: path, mimeType: mimeType, base64: base64, bytes: bytes)
  }
}
