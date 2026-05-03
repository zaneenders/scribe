import Foundation

struct EditFileToolResult: Encodable, Sendable {
  let ok = true
  let replaced: Bool
  let content: String
}

public struct EditFileTool: ScribeTool {
  public static var name: String { "edit_file" }

  public init() {}

  public func run(arguments: String) async throws -> Encodable {
    let obj = try ToolArgumentParsing.parseJSONObject(arguments)
    let path = try ToolArgumentParsing.string(obj["path"], field: "path")
    let oldS = try ToolArgumentParsing.string(obj["old_string"], field: "old_string")
    let newS = try ToolArgumentParsing.string(obj["new_string"], field: "new_string")

    var text = try FileSystemToolHelpers.readFileWhole(path: path)
    if oldS.isEmpty {
      throw PathResolution.PathError(description: "old_string must not be empty for edit_file")
    }
    let n = Self.numberOfNonOverlappingOccurrences(in: text, of: oldS)
    guard n == 1 else {
      if n == 0 {
        throw PathResolution.PathError(description: "old_string not found in file \(path)")
      }
      throw PathResolution.PathError(
        description: "old_string must be unique; found \(n) matches in \(path)"
      )
    }
    text = text.replacingOccurrences(of: oldS, with: newS, options: [], range: nil)
    let fp = try PathResolution.resolve(writing: path)
    let s = PathResolution.fileSystemPath(fp)
    try FileSystemToolHelpers.requireParentDirectoryForWrite(filesystemPath: s, userPath: path)
    try text.write(toFile: s, atomically: true, encoding: .utf8)
    return EditFileToolResult(replaced: true, content: text)
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
}
