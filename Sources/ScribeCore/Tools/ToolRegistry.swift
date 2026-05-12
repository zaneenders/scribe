import Foundation
import Logging
import ScribeLLM

public struct ToolRegistry: Sendable {
  private let tools: [String: any ScribeTool]

  /// The ChatTool schemas sent to the LLM, derived from the same tools.
  let chatTools: [Components.Schemas.ChatTool]

  private static let defaultLogger = Logger(label: "scribe.tool.registry")
  private static var logger: Logger { scribeSessionLogger ?? defaultLogger }

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
  /// A task group runs the tool while another task watches for an abort
  /// signal. When `abortNotifier` is supplied, that watcher is event-driven
  /// (it sleeps inside `notifier.signals()` until `request()` fires); when
  /// it isn't, the watcher falls back to polling `shouldAbortTurn()` every
  /// 200 ms. In both cases, `shouldAbortTurn()` remains the authoritative
  /// "should I throw" check on each wake — the notifier is only a wakeup
  /// hint.
  ///
  /// If abort fires, the tool task is cancelled — tools that use
  /// `withTaskCancellationHandler` (e.g. Shell sends SIGKILL) respond
  /// promptly.
  ///
  /// Pass `abortVia: { false }` when abort support is not needed.
  ///
  /// - Throws: `AgentTurnInterruptedError` if `shouldAbortTurn()` returns true.
  /// - Throws: `ScribeError.toolUnknown` if the tool `name` is not in the registry.
  /// - Returns: JSON-encoded tool result (or JSON error string for tool failures).
  public func run(
    name: String,
    arguments: String,
    workingDirectory: ScribeFilePath,
    abortVia shouldAbortTurn: @escaping @Sendable () -> Bool,
    abortNotifier: AbortNotifier? = nil
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
            Self.logger.trace(
              "agent.tool.task.calling-run",
              metadata: ["tool": "\(name)"])
            let value = try await tool.run(arguments: arguments, workingDirectory: workingDirectory)
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
          if let abortNotifier {
            // Event-driven path: wake the moment `notifier.request()` fires.
            // The closure remains authoritative — re-check it on each wake
            // before throwing so spurious yields (e.g. late subscribers
            // catching an already-set flag from a *previous* turn that the
            // host hasn't cleared yet) don't false-fire.
            Self.logger.trace(
              "agent.tool.abort-watch.start",
              metadata: ["tool": "\(name)", "mode": "event-driven"])
            for await _ in abortNotifier.signals() {
              if shouldAbortTurn() {
                Self.logger.trace(
                  "agent.tool.abort-watch.fired",
                  metadata: ["tool": "\(name)"])
                throw AgentTurnInterruptedError()
              }
            }
            // Stream ended without an abort — only happens when this watch
            // task itself is cancelled (the tool task already won).  Throw
            // CancellationError to satisfy the throwing-task-group's
            // `String` return contract; the group has already accepted the
            // tool's result, so this error is dropped.
            throw CancellationError()
          } else {
            // Polled fallback when caller didn't supply a notifier. 200 ms
            // strikes a balance between abort latency (still imperceptible)
            // and background cost (4× fewer wake-ups than the prior 50 ms
            // when many tools run in parallel).  Pre-tool/post-tool/post-
            // stream sites in `runAgentLoop` also check `shouldAbortTurn()`
            // synchronously, so this poll only matters during long-running
            // tool execution.
            Self.logger.trace(
              "agent.tool.abort-watch.start",
              metadata: ["tool": "\(name)", "mode": "poll"])
            var ticks = 0
            while true {
              if shouldAbortTurn() {
                Self.logger.trace(
                  "agent.tool.abort-watch.fired",
                  metadata: [
                    "tool": "\(name)", "polling_ticks": "\(ticks)",
                  ])
                throw AgentTurnInterruptedError()
              }
              try await Task.sleep(for: .milliseconds(200))
              ticks += 1
            }
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
