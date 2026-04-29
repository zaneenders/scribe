import Foundation
import Subprocess

enum Shell {
  struct Result: Sendable {
    let exitCode: TerminationStatus
    let stdout: String
    let stderr: String

    /// `JSONSerialization` only accepts Foundation types; ``TerminationStatus`` is not one of them.
    var exitCodeForJSON: Int {
      switch exitCode {
      case .exited(let code):
        return Int(code)
      #if !os(Windows)
      case .signaled(let signal):
        return 128 + Int(signal)
      #endif
      }
    }
  }

  struct ShellError: Error, CustomStringConvertible {
    let description: String
  }

  static func run(command: String, cwd: String?) async throws -> Result {
    let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw ShellError(description: "command is empty")
    }

    let workingDirectory: ScribeFilePath?
    if let cwd {
      let fp = try PathResolution.resolve(existingDirectory: cwd)
      workingDirectory = ScribeFilePath(PathResolution.fileSystemPath(fp))
    } else {
      workingDirectory = nil
    }

    let process = try await Subprocess.run(
      .path(ScribeFilePath("/bin/sh")),
      arguments: ["-c", trimmed],
      environment: .inherit,
      workingDirectory: workingDirectory,
      output: .string(limit: .max),
      error: .string(limit: .max)
    )

    return Result(
      exitCode: process.terminationStatus,
      stdout: process.standardOutput ?? "",
      stderr: process.standardError ?? ""
    )
  }
}
