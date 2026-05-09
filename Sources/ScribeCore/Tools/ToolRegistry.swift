import Foundation
import Logging
import ScribeLLM

public struct ToolRegistry: Sendable {
  private let tools: [String: any ScribeTool]

  /// The ChatTool schemas sent to the LLM, derived from the same tools.
  let chatTools: [Components.Schemas.ChatTool]

  private static let logger = Logger(label: "scribe.tool.registry")

  public init(tools: [any ScribeTool]) {
    var map: [String: any ScribeTool] = [:]
    for tool in tools {
      let name = type(of: tool).name
      map[name] = tool
    }
    self.tools = map
    self.chatTools = tools.map { type(of: $0).toChatTool() }
  }

  /// Execute a tool by name with cooperative abort support.
  ///
  /// A task group runs the tool while another task polls `shouldAbortTurn()`.
  /// If the abort condition fires, the tool task is cancelled — tools that use
  /// `withTaskCancellationHandler` (e.g. Shell sends SIGKILL) respond promptly.
  ///
  /// Pass `abortVia: { false }` when abort support is not needed.
  ///
  /// - Throws: `AgentTurnInterruptedError` if `shouldAbortTurn()` returns true.
  /// - Throws: `ScribeError.toolUnknown` if the tool `name` is not in the registry.
  /// - Returns: JSON-encoded tool result (or JSON error string for tool failures).
  public func run(
    name: String,
    arguments: String,
    abortVia shouldAbortTurn: @escaping @Sendable () -> Bool
  ) async throws -> String {
    guard let tool = tools[name] else {
      Self.logger.debug(
        "agent.tool.unknown",
        metadata: [
          "tool": "\(name)"
        ])
      throw ScribeError.toolUnknown(name: name)
    }
    let clock = ContinuousClock()
    let start = clock.now
    Self.logger.debug(
      "agent.tool.start",
      metadata: [
        "tool": "\(name)",
        "args_chars": "\(arguments.count)",
        "args": "\(arguments.logSafe())",
      ])

    // Abort before starting the tool if the flag is already set — avoids
    // a race where the tool completes but the poller ticks before we dequeue.
    if shouldAbortTurn() {
      Self.logger.debug(
        "agent.tool.aborted-before-start",
        metadata: [
          "tool": "\(name)",
          "args": "\(arguments.logSafe())",
        ])
      throw AgentTurnInterruptedError()
    }

    let json: String
    do {
      let groupStart = clock.now
      json = try await withThrowingTaskGroup(of: String.self) { group in
        group.addTask {
          do {
            let value = try await tool.run(arguments: arguments)
            let elapsed = start.duration(to: clock.now)
            let elapsedMs = Int(elapsed / .milliseconds(1))
            do {
              let encoder = JSONEncoder()
              encoder.keyEncodingStrategy = .convertToSnakeCase
              let encoded = try Self.encode(value, using: encoder)
              Self.logger.debug(
                "agent.tool.completed",
                metadata: [
                  "tool": "\(name)",
                  "elapsed_ms": "\(elapsedMs)",
                  "output_chars": "\(encoded.count)",
                  "args": "\(arguments.logSafe())",
                ])
              return encoded
            } catch {
              Self.logger.warning(
                "agent.tool.encode_failed",
                metadata: [
                  "tool": "\(name)",
                  "elapsed_ms": "\(elapsedMs)",
                  "args": "\(arguments.logSafe())",
                  "error": "\(String(describing: error).replacingOccurrences(of: "\"", with: "\\\""))",
                ])
              return Self.jsonError(String(describing: error))
            }
          } catch {
            let elapsed = start.duration(to: clock.now)
            let elapsedMs = Int(elapsed / .milliseconds(1))
            Self.logger.trace(
              "agent.tool.task.exited",
              metadata: [
                "tool": "\(name)",
                "elapsed_ms": "\(elapsedMs)",
                "args": "\(arguments.logSafe())",
                "error": "\(String(describing: error).replacingOccurrences(of: "\"", with: "\\\""))",
              ])
            return Self.jsonError(String(describing: error))
          }
        }
        group.addTask {
          Self.logger.trace(
            "agent.tool.polling.start",
            metadata: [
              "tool": "\(name)"
            ])
          while true {
            if shouldAbortTurn() {
              Self.logger.trace(
                "agent.tool.polling.abort-detected",
                metadata: [
                  "tool": "\(name)"
                ])
              throw AgentTurnInterruptedError()
            }
            try await Task.sleep(for: .milliseconds(50))
          }
        }
        let winner = try await group.next()!
        // Tool task completed — cancel the polling task so the group
        // can exit cleanly.  (In the abort case the poller already threw,
        // so cancelAll() is a harmless no-op here.)
        group.cancelAll()
        Self.logger.trace(
          "agent.tool.taskgroup.first-completed",
          metadata: [
            "tool": "\(name)",
            "elapsed_ms": "\(Int(groupStart.duration(to: clock.now) / .milliseconds(1)))",
            "result_chars": "\(winner.count)",
          ])
        return winner
      }
      let cleanupMs = Int(start.duration(to: clock.now) / .milliseconds(1))
      Self.logger.trace(
        "agent.tool.taskgroup.all-completed",
        metadata: [
          "tool": "\(name)",
          "cleanup_elapsed_ms": "\(cleanupMs)",
        ])
    } catch is AgentTurnInterruptedError {
      let elapsedMs = Int(start.duration(to: clock.now) / .milliseconds(1))
      Self.logger.debug(
        "agent.tool.errored",
        metadata: [
          "tool": "\(name)",
          "elapsed_ms": "\(elapsedMs)",
          "args": "\(arguments.logSafe())",
          "error": "AgentTurnInterruptedError",
        ])
      throw AgentTurnInterruptedError()
    } catch {
      let elapsed = start.duration(to: clock.now)
      let elapsedMs = Int(elapsed / .milliseconds(1))
      Self.logger.debug(
        "agent.tool.errored",
        metadata: [
          "tool": "\(name)",
          "elapsed_ms": "\(elapsedMs)",
          "args": "\(arguments.logSafe())",
          "error": "\(String(describing: error).replacingOccurrences(of: "\"", with: "\\\""))",
        ])
      return Self.jsonError(String(describing: error))
    }

    return json
  }

  // MARK: - Encoding helpers

  private static func encode<T: Encodable>(_ value: T, using encoder: JSONEncoder) throws -> String {
    let data = try encoder.encode(value)
    return String(data: data, encoding: .utf8) ?? jsonSerializationFallback
  }

  private static let jsonSerializationFallback =
    "{\"ok\":false,\"error\":\"tool result could not be encoded as JSON\"}"

  static func jsonError(_ text: String) -> String {
    let payload: [String: Any] = ["ok": false, "error": text]
    do {
      let data = try JSONSerialization.data(withJSONObject: payload, options: [])
      return String(data: data, encoding: .utf8) ?? jsonSerializationFallback
    } catch {
      return jsonSerializationFallback
    }
  }
}

extension String {
  /// Escape quotes and truncate to a reasonable length for structured log lines.
  func logSafe(maxLength: Int = 500) -> String {
    let escaped = replacingOccurrences(of: "\"", with: "\\\"")
    if escaped.count <= maxLength {
      return escaped
    }
    return String(escaped.prefix(maxLength)) + "..."
  }
}
