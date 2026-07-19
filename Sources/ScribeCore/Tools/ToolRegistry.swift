import Foundation
import Logging
import ScribeLLM
import SystemPackage

public struct ToolRegistry: Sendable, ToolExecutor {
  private let tools: [String: any ScribeTool]

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
            let modelOutput = (value as? AttachableToolResult)?.attachmentToolResultText
              ?? encoded
            let toolResult = ToolResult(
              text: modelOutput, attachments: attachments, warnings: warnings)
            let logLevel: Logger.Level = toolResult.textWasTruncated ? .warning : .debug
            logger.log(
              level: logLevel,
              "agent.tool.completed",
              metadata: [
                "tool": "\(name)",
                "elapsed_ms": "\(elapsedMs)",
                "encoded_output_chars": "\(encoded.count)",
                "model_output_chars": "\(modelOutput.count)",
                "bounded_output_chars": "\(toolResult.text.count)",
                "bounded_output_bytes": "\(toolResult.text.utf8.count)",
                "global_output_truncated": "\(toolResult.textWasTruncated)",
                "attachment_payload_omitted_from_model_output": "\(modelOutput.count != encoded.count)",
                "attachments": "\(attachments.count)",
                "warnings": "\(toolResult.warnings.count)",
                "args": "\(arguments.logSafe())",
              ])
            return toolResult
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

  private static func encode<T: Encodable>(_ value: T, using encoder: JSONEncoder) throws -> String {
    let data = try encoder.encode(value)
    return String(data: data, encoding: .utf8) ?? jsonSerializationFallback
  }

  private static let jsonSerializationFallback =
    "{\"ok\":false,\"error\":\"tool result could not be encoded as JSON\"}"

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

  func logSafe(maxLength: Int = 500) -> String {
    let escaped = replacingOccurrences(of: "\"", with: "\\\"")
    if escaped.count <= maxLength {
      return escaped
    }
    return String(escaped.prefix(maxLength)) + "..."
  }
}
