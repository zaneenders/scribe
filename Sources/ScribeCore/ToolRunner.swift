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
        let text = try readFile(path: path)
        return .init(text: jsonOk(["content": text]))

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

  private static func readFile(path: String) throws -> String {
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
    var text = try readFile(path: path)
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
