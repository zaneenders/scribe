import Foundation

enum ToolArgumentParsing {
  static func parseJSONObject(_ arguments: String) throws -> [String: Any] {
    let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return [:] }
    let any = try JSONSerialization.jsonObject(with: Data(arguments.utf8), options: [])
    return (any as? [String: Any]) ?? [:]
  }

  static func string(_ v: Any?, field: String) throws -> String {
    guard let v, let s = v as? String, !s.isEmpty else {
      throw PathResolution.PathError(description: "missing or empty field \(field)")
    }
    return s
  }

  static func optionalString(_ v: Any?) -> String? {
    (v as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func optionalInt(_ v: Any?) -> Int? {
    if let n = v as? Int { return n }
    if let n = v as? Double { return Int(n) }
    if let s = (v as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
      return Int(s)
    }
    return nil
  }
}
