import SystemPackage
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

/// **`shell`** runs commands via `/bin/sh -c`. Stdout and stderr are streamed to per-invocation
/// temp files (under the system temporary directory, e.g. `/tmp/` on Linux). The tool result
/// returns `stdoutFile` and `stderrFile` paths rather than inline output — the agent reads them
/// with `read_file` when it needs the contents. These temp files are not automatically cleaned
/// up; they persist until the system purges its temp directory (on reboot for Linux tmpfs, or
/// periodically on macOS).
public struct ShellTool: ScribeTool {
  public static var name: String { "shell" }
  public static var description: String {
    "Run a command via /bin/sh -c. "
      + "Stdout and stderr are streamed to per-invocation temp files; "
      + "the result returns `stdoutFile` and `stderrFile` paths — "
      + "use `read_file` to inspect output."
  }
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
  public static var promptHint: String? {
    "For `shell`, output is written to temp files — use `read_file` on the returned "
      + "`stdoutFile` / `stderrFile` paths to see results. The files are always present "
      + "(empty when there was no output)."
  }

  public init() {}

  public func run(arguments: String, workingDirectory: FilePath, logger: Logger) async throws -> Encodable {
    let obj = try ToolArgumentParsing.parseJSONObject(arguments)
    let command = try ToolArgumentParsing.string(obj["command"], field: "command")
    var cwd: String? = ToolArgumentParsing.optionalString(obj["cwd"])
    if let c = cwd, c.isEmpty { cwd = nil }
    let result = try await Shell.run(
      command: command, cwd: cwd, workingDirectory: workingDirectory, logger: logger)
    logger.debug(
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
