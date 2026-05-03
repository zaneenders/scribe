import Foundation

struct WriteFileToolResult: Encodable, Sendable {
  let ok = true
  let written: Bool
}

public struct WriteFileTool: ScribeTool {
  public static var name: String { "write_file" }

  public init() {}

  public func run(arguments: String) async throws -> Encodable {
    let obj = try ToolArgumentParsing.parseJSONObject(arguments)
    let path = try ToolArgumentParsing.string(obj["path"], field: "path")
    let content = try ToolArgumentParsing.string(obj["content"], field: "content")
    let fp = try PathResolution.resolve(writing: path)
    let s = PathResolution.fileSystemPath(fp)
    try FileSystemToolHelpers.requireParentDirectoryForWrite(filesystemPath: s, userPath: path)
    try content.write(toFile: s, atomically: true, encoding: .utf8)
    return WriteFileToolResult(written: true)
  }
}
