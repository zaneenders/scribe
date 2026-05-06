import Foundation
import Logging
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

  private static let logger = Logger(label: "scribe.tool.shell")

  /// Run a shell command, supporting cooperative cancellation.
  ///
  /// When the calling `Task` is cancelled, a `SIGKILL` is sent to the entire
  /// process group so long-running commands (builds, servers, etc.) and all
  /// of their child processes are terminated.
  static func run(command: String, cwd: String?) async throws -> Result {
    let id = UUID()
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

    logger.trace("Starting shell[\(id)]: \(command), in:\(workingDirectory ?? "nil")")

    // Use the body-based Subprocess API to get an Execution handle so we can
    // send SIGKILL to the process group on cancellation.  Output is collected
    // manually from the AsyncBufferSequence streams.
    var platformOptions = PlatformOptions()
    platformOptions.processGroupID = 0
    let outcome = try await Subprocess.run(
      .path(ScribeFilePath("/bin/sh")),
      arguments: ["-c", trimmed],
      environment: .inherit,
      workingDirectory: workingDirectory,
      platformOptions: platformOptions
    ) { execution, _, outputSequence, errorSequence in
      try await withTaskCancellationHandler {
        logger.trace("shell[\(id)] completed")
        // Collect stdout and stderr concurrently.
        async let out = collectString(from: outputSequence)
        async let err = collectString(from: errorSequence)
        return try await (out, err)
      } onCancel: {
        do {
          logger.trace("shell[\(id)] cancelling")
          // Best-effort interrupt — the process may already have exited.
          #if os(Windows)
          try execution.terminate(withExitCode: 0)
          #else
          // send to the entire process group so children (swiftc, etc.)
          // are killed alongside the shell.  setsid() above ensures the
          // child is a process-group leader.
          try execution.send(signal: .kill, toProcessGroup: true)
          #endif
        } catch {
          logger.trace("shell[\(id)] cancellation failed: \(error)")
        }
      }
    }

    return Result(
      exitCode: outcome.terminationStatus,
      stdout: outcome.value.0,
      stderr: outcome.value.1
    )
  }

  /// Drain an ``AsyncBufferSequence`` into a single `String`.
  private static func collectString(from sequence: AsyncBufferSequence) async throws -> String {
    var result = ""
    for try await buffer in sequence {
      result += buffer.withUnsafeBytes { raw in
        String(decoding: raw, as: UTF8.self)
      }
    }
    return result
  }
}
