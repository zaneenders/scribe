import Foundation

public struct ToolRegistry: Sendable {
  private let tools: [String: any ScribeTool]

  public init(tools: [any ScribeTool]) {
    var map: [String: any ScribeTool] = [:]
    for tool in tools {
      let name = type(of: tool).name
      map[name] = tool
    }
    self.tools = map
  }

  public func run(name: String, arguments: String) async -> String {
    guard let tool = tools[name] else {
      return Self.jsonError("unknown tool \(name)")
    }
    do {
      let result = try await tool.run(arguments: arguments)
      let encoder = JSONEncoder()
      encoder.keyEncodingStrategy = .convertToSnakeCase
      return try Self.encode(result, using: encoder)
    } catch {
      return Self.jsonError(String(describing: error))
    }
  }

  // MARK: - Encoding helpers

  private static func encode<T: Encodable>(_ value: T, using encoder: JSONEncoder) throws -> String {
    let data = try encoder.encode(value)
    return String(data: data, encoding: .utf8) ?? jsonSerializationFallback
  }

  private static let jsonSerializationFallback =
    "{\"ok\":false,\"error\":\"tool result could not be encoded as JSON\"}"

  private static func jsonError(_ text: String) -> String {
    let payload: [String: Any] = ["ok": false, "error": text]
    do {
      let data = try JSONSerialization.data(withJSONObject: payload, options: [])
      return String(data: data, encoding: .utf8) ?? jsonSerializationFallback
    } catch {
      return jsonSerializationFallback
    }
  }
}
