import SystemPackage
import Foundation
import Logging
import ScribeLLM

public struct ToolRegistry: Sendable, ToolExecutor {
  private let tools: [String: any ScribeTool]

  // The ChatTool schemas sent to the LLM, derived from the same tools.
  let chatTools: [Components.Schemas.ChatTool]

  public init(tools: [any ScribeTool], logger: Logger) {
    var map: [String: any ScribeTool] = [:]
    for tool in tools {
      let name = type(of: tool).name
      map[name] = tool
    }
    self.tools = map
    self.chatTools = tools.map { type(of: $0).toChatTool(logger: logger) }
  }

  /// ``ToolExecutor`` conformance: route a resolved invocation through the
  /// registry's abort-aware `run(name:arguments:...)` helper.
  public func execute(
    _ invocation: ToolInvocation,
    workingDirectory: FilePath,
    logger: Logger,
    abort: any AbortObserver
  ) async throws -> ToolResult {
    try await run(
      name: invocation.name,
      arguments: invocation.arguments,
      workingDirectory: workingDirectory,
      logger: logger,
      abortObserver: abort
    )
  }

  /// Execute a tool by name with cooperative abort support.
  ///
  /// A task group runs the tool while a watch task sleeps inside
  /// `abortObserver.signals()`. When the upstream notifier fires, the
  /// watch task wakes, re-checks `abortObserver.isAborted()` (cheap
  /// defence against spurious yields from late subscribers catching a
  /// residual signal), and throws `AgentTurnInterruptedError` — which
  /// cancels the tool task. Tools that use `withTaskCancellationHandler`
  /// (e.g. Shell sends SIGKILL) respond promptly.
  ///
  /// Pass `abortObserver: AbortNotifier()` when abort support isn't
  /// needed — that notifier never fires and the watch task simply
  /// suspends until the tool finishes and the group is cancelled.
  ///
  /// - Throws: `AgentTurnInterruptedError` if abort fires.
  /// - Throws: `ScribeError.toolUnknown` if the tool `name` is not in the registry.
  /// - Returns: `ToolResult` with JSON-encoded tool output and any attachments.
  internal func run(
    name: String,
    arguments: String,
    workingDirectory: FilePath,
    logger: Logger,
    abortObserver: some AbortObserver
  ) async throws -> ToolResult {
    guard let tool = tools[name] else {
      logger.debug(
        "agent.tool.unknown",
        metadata: [
          "tool": "\(name)"
        ])
      throw ScribeError.toolUnknown(name: name)
    }
    let clock = ContinuousClock()
    let start = clock.now
    logger.debug(
      "agent.tool.start",
      metadata: [
        "tool": "\(name)",
        "args_chars": "\(arguments.count)",
        "args": "\(arguments.logSafe())",
      ])

    // Abort before starting the tool if the flag is already set — avoids
    // a race where the tool completes but the watch task wakes before we
    // dequeue.
    if abortObserver.isAborted() {
      logger.debug(
        "agent.tool.aborted-before-start",
        metadata: [
          "tool": "\(name)",
          "args": "\(arguments.logSafe())",
        ])
      throw AgentTurnInterruptedError()
    }

    let result: ToolResult
    do {
      result = try await abortObserver.race {
        [tool, arguments, workingDirectory, logger, start, clock, name] in
        logger.trace("agent.tool.task.calling-run", metadata: ["tool": "\(name)"])
        do {
          let value = try await tool.run(
            arguments: arguments, workingDirectory: workingDirectory, logger: logger)
          let elapsedMs = Int(start.duration(to: clock.now) / .milliseconds(1))
          do {
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            let encoded = try Self.encode(value, using: encoder)
            let attachments: [ToolAttachment]
            if let attachable = value as? AttachableToolResult {
              attachments = attachable.toolAttachments
              if !attachments.isEmpty {
                logger.info(
                  "agent.tool.attachments.detected",
                  metadata: [
                    "tool": "\(name)",
                    "count": "\(attachments.count)",
                    "mime_types": "\(attachments.map(\.mimeType).joined(separator: ", "))",
                    "total_base64_chars": "\(attachments.map(\.base64.count).reduce(0, +))",
                  ])
              }
            } else {
              attachments = []
            }
            let warnings = (value as? WarnableToolResult)?.toolWarnings ?? []
            logger.debug(
              "agent.tool.completed",
              metadata: [
                "tool": "\(name)",
                "elapsed_ms": "\(elapsedMs)",
                "output_chars": "\(encoded.count)",
                "attachments": "\(attachments.count)",
                "warnings": "\(warnings.count)",
                "args": "\(arguments.logSafe())",
              ])
            return ToolResult(text: encoded, attachments: attachments, warnings: warnings)
          } catch {
            logger.warning(
              "agent.tool.encode_failed",
              metadata: [
                "tool": "\(name)",
                "elapsed_ms": "\(elapsedMs)",
                "args": "\(arguments.logSafe())",
                "error": "\(String(describing: error).replacingOccurrences(of: "\"", with: "\\\""))",
              ])
            return ToolResult.text(Self.jsonError(String(describing: error)))
          }
        } catch {
          // Convert any tool error (including AgentTurnInterruptedError thrown
          // by the tool itself) to a JSON error result. This keeps tool-level
          // failures as recoverable tool messages rather than loop aborts.
          // CancellationError from abort-race cancellation is also caught here
          // but its result is discarded — the watcher task already won the race.
          let elapsedMs = Int(start.duration(to: clock.now) / .milliseconds(1))
          logger.trace(
            "agent.tool.task.exited",
            metadata: [
              "tool": "\(name)",
              "elapsed_ms": "\(elapsedMs)",
              "args": "\(arguments.logSafe())",
              "error": "\(String(describing: error).replacingOccurrences(of: "\"", with: "\\\""))",
            ])
          return ToolResult.text(Self.jsonError(String(describing: error)))
        }
      }
    } catch is AgentTurnInterruptedError {
      // Only the watcher task throws AgentTurnInterruptedError out of `race`
      // (tool errors are converted above). Re-throw to unwind the agent loop.
      let elapsedMs = Int(start.duration(to: clock.now) / .milliseconds(1))
      logger.debug(
        "agent.tool.errored",
        metadata: [
          "tool": "\(name)",
          "elapsed_ms": "\(elapsedMs)",
          "args": "\(arguments.logSafe())",
          "error": "AgentTurnInterruptedError",
        ])
      throw AgentTurnInterruptedError()
    }

    return result
  }

  // MARK: - Encoding helpers

  private static func encode<T: Encodable>(_ value: T, using encoder: JSONEncoder) throws -> String {
    let data = try encoder.encode(value)
    return String(data: data, encoding: .utf8) ?? jsonSerializationFallback
  }

  private static let jsonSerializationFallback =
    "{\"ok\":false,\"error\":\"tool result could not be encoded as JSON\"}"

  /// Convenience builder for the `{"ok": false, "error": "..."}` JSON
  /// shape that the agent loop and built-in tools use to surface tool
  /// failures to the assistant. Exposed so custom ``ToolExecutor``s can
  /// produce matching error payloads.
  public static func jsonError(_ text: String) -> String {
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
