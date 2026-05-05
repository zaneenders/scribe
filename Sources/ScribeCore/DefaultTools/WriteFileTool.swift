import Foundation
import Logging

struct WriteFileToolResult: Encodable, Sendable {
  let ok = true
  let written: Bool
}

public struct WriteFileTool: ScribeTool {
  public static var name: String { "write_file" }
  public static var description: String { "Create or overwrite a file (parent directory must exist)." }
  public static var parameters: [ScribeToolParameter] {
    [
      ScribeToolParameter(
        name: "path", type: .string,
        description: "Filesystem path (relative paths resolve against the process cwd).",
        required: true),
      ScribeToolParameter(
        name: "content", type: .string, description: "Full file contents.", required: true),
    ]
  }
  public static var promptHint: String? { nil }

  public init() {}

  private static let logger = Logger(label: "scribe.tool.write_file")

  public func run(arguments: String) async throws -> Encodable {
    let obj = try ToolArgumentParsing.parseJSONObject(arguments)
    let path = try ToolArgumentParsing.string(obj["path"], field: "path")
    let content = try ToolArgumentParsing.string(obj["content"], field: "content")
    let fp = try PathResolution.resolve(writing: path)
    let s = PathResolution.fileSystemPath(fp)
    try FileSystemToolHelpers.requireParentDirectoryForWrite(filesystemPath: s, userPath: path)
    try content.write(toFile: s, atomically: true, encoding: .utf8)
    Self.logger.debug(
      """
      event=agent.tool.write_file \
      path="\(s.replacingOccurrences(of: "\"", with: "\\\""))" \
      bytes_written=\(content.utf8.count)
      """)
    return WriteFileToolResult(written: true)
  }
}
