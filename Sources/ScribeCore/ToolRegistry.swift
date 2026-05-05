import Foundation
import Logging

public struct ToolRegistry: Sendable {
  private let tools: [String: any ScribeTool]

  private static let logger = Logger(label: "scribe.tool.registry")

  public init(tools: [any ScribeTool]) {
    var map: [String: any ScribeTool] = [:]
    for tool in tools {
      let name = type(of: tool).name
      map[name] = tool
    }
    self.tools = map
  }

  /// Execute a tool by name, logging start/completed/errored events
  /// with wall-clock duration measured by `ContinuousClock`.
  public func run(name: String, arguments: String) async -> String {
    guard let tool = tools[name] else {
      Self.logger.debug(
        """
        event=agent.tool.unknown \
        tool=\(name)
        """)
      return Self.jsonError("unknown tool \(name)")
    }
    let clock = ContinuousClock()
    let start = clock.now
    Self.logger.debug(
      """
      event=agent.tool.start \
      tool=\(name) \
      args_chars=\(arguments.count)
      """)
    do {
      let result = try await tool.run(arguments: arguments)
      let elapsed = start.duration(to: clock.now)
      let elapsedMs = Int(elapsed / .milliseconds(1))
      let encoder = JSONEncoder()
      encoder.keyEncodingStrategy = .convertToSnakeCase
      do {
        let json = try Self.encode(result, using: encoder)
        Self.logger.debug(
          """
          event=agent.tool.completed \
          tool=\(name) \
          elapsed_ms=\(elapsedMs) \
          output_chars=\(json.count)
          """)
        return json
      } catch {
        Self.logger.warning(
          """
          event=agent.tool.encode_failed \
          tool=\(name) \
          elapsed_ms=\(elapsedMs) \
          error="\(String(describing: error).replacingOccurrences(of: "\"", with: "\\\""))"
          """)
        return Self.jsonError(String(describing: error))
      }
    } catch {
      let elapsed = start.duration(to: clock.now)
      let elapsedMs = Int(elapsed / .milliseconds(1))
      Self.logger.debug(
        """
        event=agent.tool.errored \
        tool=\(name) \
        elapsed_ms=\(elapsedMs) \
        error="\(String(describing: error).replacingOccurrences(of: "\"", with: "\\\""))"
        """)
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
