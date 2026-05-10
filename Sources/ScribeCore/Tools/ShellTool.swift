import Foundation
import Logging

struct ShellToolResult: Encodable, Sendable {
  let ok = true
  let exitCode: Int
  /// Path to temp file containing stdout (always present, may be empty).
  let stdoutFile: String
  /// Path to temp file containing stderr (always present, may be empty).
  let stderrFile: String
  let pid: pid_t
}

public struct ShellTool: ScribeTool {
  public static var name: String { "shell" }
  public static var description: String { "Run a command via /bin/sh -c." }
  public static var parameters: [ScribeToolParameter] {
    [
      ScribeToolParameter(
        name: "command", type: .string,
        description: "Shell command to run (passed to /bin/sh -c).", required: true),
      ScribeToolParameter(
        name: "cwd", type: .string,
        description:
          "Optional working directory for the command (relative paths resolve against the process cwd).",
        required: false),
    ]
  }
  public static var promptHint: String? { nil }

  public init() {}

  private static let logger = Logger(label: "scribe.tool.shell")

  public func run(arguments: String, workingDirectory: ScribeFilePath) async throws -> Encodable {
    let obj = try ToolArgumentParsing.parseJSONObject(arguments)
    let command = try ToolArgumentParsing.string(obj["command"], field: "command")
    var cwd: String? = ToolArgumentParsing.optionalString(obj["cwd"])
    if let c = cwd, c.isEmpty { cwd = nil }
    let result = try await Shell.run(command: command, cwd: cwd, workingDirectory: workingDirectory)
    Self.logger.debug(
      "agent.tool.shell",
      metadata: [
        "pid": "\(result.pid)",
        "exit_code": "\(result.exitCodeForJSON)",
        "stdout_file": "\(result.stdoutFile.string)",
        "stderr_file": "\(result.stderrFile.string)",
      ])
    return ShellToolResult(
      exitCode: result.exitCodeForJSON,
      stdoutFile: result.stdoutFile.string,
      stderrFile: result.stderrFile.string,
      pid: result.pid
    )
  }
}
