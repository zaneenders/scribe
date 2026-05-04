import Foundation

struct ShellToolResult: Encodable, Sendable {
  let ok = true
  let exitCode: Int
  let stdout: String
  let stderr: String
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

  public func run(arguments: String) async throws -> Encodable {
    let obj = try ToolArgumentParsing.parseJSONObject(arguments)
    let command = try ToolArgumentParsing.string(obj["command"], field: "command")
    var cwd: String? = ToolArgumentParsing.optionalString(obj["cwd"])
    if let c = cwd, c.isEmpty { cwd = nil }
    let result = try await Shell.run(command: command, cwd: cwd)
    return ShellToolResult(
      exitCode: result.exitCodeForJSON,
      stdout: result.stdout,
      stderr: result.stderr
    )
  }
}
