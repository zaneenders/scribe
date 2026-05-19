import Foundation
import Logging
import Subprocess
import SystemPackage

// TODO: Address logging mess.
package nonisolated(unsafe) var scribeSessionLogger: Logger?

/// Thin orchestrator for "run a shell command, capture its output, kill
/// the whole tree on cancellation."
///
/// Delegates the meaty bits to focused collaborators:
/// - `OutputCapture` — temp files, drain task, post-cancel deadline.
/// - `ProcessKiller` — platform-specific tree kill (`/proc` walk on Linux,
///   pgroup signal on macOS, `terminate` on Windows).
///
/// Public API (`Shell.run(command:cwd:workingDirectory:)`) is unchanged
/// from before the split.
enum Shell {
  struct Result: Sendable {
    let exitCode: TerminationStatus
    let stdoutFile: FilePath
    let stderrFile: FilePath
    let pid: pid_t

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

  private static let defaultLogger = Logger(label: "scribe.tool.shell")
  private static var logger: Logger { scribeSessionLogger ?? defaultLogger }

  /// Run a shell command, supporting cooperative cancellation.
  ///
  /// When the calling `Task` is cancelled, the configured `ProcessKiller`
  /// terminates the process tree so long-running commands (builds,
  /// servers, etc.) and all of their child processes go away.
  ///
  /// Stdout and stderr are streamed to temp files (one per stream) so the
  /// LLM can read them with the `read_file` tool when it needs the
  /// contents.
  ///
  /// `killer` is injectable for tests — pass `.platformDefault` (the
  /// default) in production, a stub in tests that want to inspect what
  /// would have been killed without invoking real `kill(2)` syscalls.
  static func run(
    command: String,
    cwd: String?,
    workingDirectory: FilePath,
    killer: any ProcessKiller = DefaultProcessKiller()
  ) async throws -> Result {
    let id = UUID()
    let t0 = ContinuousClock.now
    let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw ShellError(description: "command is empty")
    }

    logger.trace(
      "shell-run-entry",
      metadata: [
        "shell_id": "\(id)", "command": "\(trimmed.logSafe())",
        "cancelled_at_entry": "\(Task.isCancelled)",
      ])

    let shellCwd: FilePath?
    if let cwd {
      let fp = try PathResolution.resolve(existingDirectory: cwd, cwd: workingDirectory)
      shellCwd = FilePath(fp.string)
    } else {
      shellCwd = nil
    }

    let capture = try OutputCapture.create(
      id: id, in: FileManager.default.temporaryDirectory)

    logger.trace(
      "shell-tempfiles-ready",
      metadata: [
        "shell_id": "\(id)",
        "stdout_file": "\(capture.stdoutURL.path)",
        "stderr_file": "\(capture.stderrURL.path)",
      ])

    var platformOptions = PlatformOptions()
    platformOptions.processGroupID = 0

    let t1 = ContinuousClock.now
    logger.trace(
      "shell-entering-subprocess-run",
      metadata: [
        "shell_id": "\(id)", "elapsed_us": "\(t0.duration(to: t1).microseconds)",
        "cancelled": "\(Task.isCancelled)",
      ])

    let outcome: ExecutionOutcome<(pid_t, Int, Int)>
    do {
      outcome = try await Subprocess.run(
        .path(FilePath("/bin/sh")),
        arguments: ["-c", trimmed],
        environment: .inherit,
        workingDirectory: shellCwd,
        platformOptions: platformOptions
      ) { execution, _, outputSequence, errorSequence in
        let pid = execution.processIdentifier.value
        let tBody = ContinuousClock.now
        logger.trace(
          "shell-body-entered",
          metadata: [
            "shell_id": "\(id)", "pid": "\(pid)",
            "elapsed_since_entry_us": "\(t0.duration(to: tBody).microseconds)",
            "cancelled": "\(Task.isCancelled)",
          ])

        return try await withTaskCancellationHandler {
          logger.trace(
            "shell-drain-start",
            metadata: [
              "shell_id": "\(id)", "pid": "\(pid)",
              "cancelled": "\(Task.isCancelled)",
              "handler_registered": "true",
            ])
          let tDrain = ContinuousClock.now

          let drainTask = capture.startDrain(
            stdout: outputSequence,
            stderr: errorSequence,
            pid: pid,
            logger: logger)

          let bytes: DrainBytes
          do {
            bytes = try await drainTask.value
            logger.trace(
              "shell-drain-complete",
              metadata: [
                "shell_id": "\(id)", "pid": "\(pid)",
                "out_bytes": "\(bytes.out)", "err_bytes": "\(bytes.err)",
                "drain_elapsed_us": "\(tDrain.duration(to: .now).microseconds)",
                "cancelled": "\(Task.isCancelled)",
              ])
          } catch is CancellationError {
            // Parent cancelled mid-drain. Race the (still-running) detached
            // drain against a hard deadline so a setsid grandchild that
            // keeps the pipe open can't hang us indefinitely. See
            // OutputCapture.awaitDrainWithDeadline for the cancellation
            // gymnastics.
            if let drained = await OutputCapture.awaitDrainWithDeadline(
              drainTask: drainTask, deadlineMs: 2_000,
              shellID: id, logger: logger)
            {
              bytes = drained
              logger.trace(
                "shell-drain-completed-after-cancel",
                metadata: [
                  "shell_id": "\(id)", "pid": "\(pid)",
                  "out_bytes": "\(bytes.out)", "err_bytes": "\(bytes.err)",
                  "drain_elapsed_us": "\(tDrain.duration(to: .now).microseconds)",
                ])
            } else {
              capture.closeHandles()
              bytes = capture.diskSizes()
              logger.trace(
                "shell-drain-deadline-reached",
                metadata: [
                  "shell_id": "\(id)", "pid": "\(pid)",
                  "drain_elapsed_us": "\(tDrain.duration(to: .now).microseconds)",
                  "out_bytes_on_disk": "\(bytes.out)",
                  "err_bytes_on_disk": "\(bytes.err)",
                ])
            }
          } catch {
            drainTask.cancel()
            logger.trace(
              "shell-drain-error",
              metadata: [
                "shell_id": "\(id)", "pid": "\(pid)",
                "error": "\(String(describing: error))",
                "drain_elapsed_us": "\(tDrain.duration(to: .now).microseconds)",
              ])
            throw error
          }

          capture.closeHandles()
          logger.trace(
            "shell-drain-handles-closed",
            metadata: ["shell_id": "\(id)", "pid": "\(pid)"])
          return (pid, bytes.out, bytes.err)
        } onCancel: {
          let tCancel = ContinuousClock.now
          logger.trace(
            "shell-onCancel-fired",
            metadata: [
              "shell_id": "\(id)", "pid": "\(pid)",
              "elapsed_since_entry_us": "\(t0.duration(to: tCancel).microseconds)",
            ])

          // Kill the process tree first so the async sequences hit EOF.
          // writeStream will drain any remaining buffered output and
          // return naturally — do NOT close handles here or we lose
          // partial output that hasn't been delivered yet. The body's
          // `catch is CancellationError` path closes handles once drain
          // returns and reads partial sizes from disk.
          let killed = killer.killTree(
            rootPid: pid,
            execution: execution,
            logger: logger,
            shellID: id)
          logger.trace(
            "shell-onCancel-complete",
            metadata: [
              "shell_id": "\(id)", "pid": "\(pid)",
              "killed_count": "\(killed)",
              "onCancel_elapsed_us": "\(tCancel.duration(to: .now).microseconds)",
            ])
        }
      }
    } catch {
      logger.trace(
        "shell-subprocess-run-threw",
        metadata: [
          "shell_id": "\(id)", "error": "\(String(describing: error))",
          "total_elapsed_us": "\(t0.duration(to: .now).microseconds)",
        ])
      throw error
    }

    let tEnd = ContinuousClock.now
    let totalUs = t0.duration(to: tEnd).microseconds
    let onDisk = capture.diskSizes()
    logger.trace(
      "shell-run-returning",
      metadata: [
        "shell_id": "\(id)",
        "pid": "\(outcome.value.0)",
        "termination": "\(String(describing: outcome.terminationStatus))",
        "out_bytes": "\(outcome.value.1)",
        "err_bytes": "\(outcome.value.2)",
        "out_file_bytes": "\(onDisk.out)",
        "err_file_bytes": "\(onDisk.err)",
        "total_elapsed_us": "\(totalUs)",
      ])
    return Result(
      exitCode: outcome.terminationStatus,
      stdoutFile: capture.stdoutFile,
      stderrFile: capture.stderrFile,
      pid: outcome.value.0
    )
  }
}

extension Duration {
  var microseconds: Int64 {
    let (seconds, attoseconds) = self.components
    return seconds * 1_000_000 + attoseconds / 1_000_000_000_000
  }
}
