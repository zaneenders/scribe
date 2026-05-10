import Foundation
import Logging
import Subprocess

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

enum Shell {
  struct Result: Sendable {
    let exitCode: TerminationStatus
    /// Path to a temp file containing stdout (always set, may be an empty file).
    let stdoutFile: ScribeFilePath
    /// Path to a temp file containing stderr (always set, may be an empty file).
    let stderrFile: ScribeFilePath
    let pid: pid_t

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
  ///
  /// Stdout and stderr are streamed to temp files (one per stream) so the LLM
  /// can read them with the `read_file` tool when it needs the contents.
  static func run(command: String, cwd: String?, workingDirectory: ScribeFilePath) async throws -> Result {
    let id = UUID()
    let t0 = ContinuousClock.now
    let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw ShellError(description: "command is empty")
    }

    let shellCwd: ScribeFilePath?
    if let cwd {
      let fp = try PathResolution.resolve(existingDirectory: cwd, cwd: workingDirectory)
      shellCwd = ScribeFilePath(fp.fileSystemPath)
    } else {
      shellCwd = nil
    }

    // Temp files for stdout and stderr.
    let tmpDir = FileManager.default.temporaryDirectory
    let stdoutURL = tmpDir.appendingPathComponent("scribe-shell-\(id.uuidString)-stdout.txt")
    let stderrURL = tmpDir.appendingPathComponent("scribe-shell-\(id.uuidString)-stderr.txt")
    let stdoutPath = ScribeFilePath(stdoutURL.path)
    let stderrPath = ScribeFilePath(stderrURL.path)

    // Ensure empty files exist so the paths are always valid even with zero output.
    try "".write(to: stdoutURL, atomically: false, encoding: .utf8)
    try "".write(to: stderrURL, atomically: false, encoding: .utf8)

    logger.trace(
      "shell-run-entry",
      metadata: [
        "shell_id": "\(id)", "command": "\(trimmed)", "cwd": "\(shellCwd ?? "nil")",
        "stdout_file": "\(stdoutURL.path)", "stderr_file": "\(stderrURL.path)",
        "cancelled_at_entry": "\(Task.isCancelled)",
      ])

    // Open file handles up front so onCancel can close them as a safety net.
    guard let stdoutHandle = try? FileHandle(forWritingTo: stdoutURL),
          let stderrHandle = try? FileHandle(forWritingTo: stderrURL) else {
      logger.error("shell-handle-open-failed", metadata: ["shell_id": "\(id)"])
      throw ShellError(description: "could not open temp files for writing")
    }

    var platformOptions = PlatformOptions()
    platformOptions.processGroupID = 0

    let t1 = ContinuousClock.now
    logger.trace("shell-entering-subprocess-run", metadata: [
      "shell_id": "\(id)", "elapsed_us": "\(t0.duration(to: t1).microseconds)",
      "cancelled": "\(Task.isCancelled)",
    ])

    let outcome: ExecutionOutcome<(pid_t, Int, Int)>
    do {
      outcome = try await Subprocess.run(
        .path(ScribeFilePath("/bin/sh")),
        arguments: ["-c", trimmed],
        environment: .inherit,
        workingDirectory: shellCwd,
        platformOptions: platformOptions
      ) { execution, _, outputSequence, errorSequence in
        let pid = execution.processIdentifier.value
        let tBody = ContinuousClock.now
        logger.trace("shell-body-entered", metadata: [
          "shell_id": "\(id)", "pid": "\(pid)",
          "elapsed_since_entry_us": "\(t0.duration(to: tBody).microseconds)",
          "cancelled": "\(Task.isCancelled)",
        ])

        return try await withTaskCancellationHandler {
          logger.trace("shell-drain-start", metadata: [
            "shell_id": "\(id)", "pid": "\(pid)",
            "cancelled": "\(Task.isCancelled)",
          ])
          let tDrain = ContinuousClock.now

          async let outBytes = writeStream(
            from: outputSequence, to: stdoutHandle,
            label: "\(id)/stdout", pid: pid, shellID: id)
          async let errBytes = writeStream(
            from: errorSequence, to: stderrHandle,
            label: "\(id)/stderr", pid: pid, shellID: id)

          let result: (pid_t, Int, Int)
          do {
            result = try await (pid, outBytes, errBytes)
            logger.trace("shell-drain-complete", metadata: [
              "shell_id": "\(id)", "pid": "\(pid)",
              "out_bytes": "\(result.1)", "err_bytes": "\(result.2)",
              "drain_elapsed_us": "\(tDrain.duration(to: ContinuousClock.now).microseconds)",
              "cancelled": "\(Task.isCancelled)",
            ])
          } catch is CancellationError {
            // writeStream threw CancellationError (from Task.checkCancellation).
            // Handles are already closed by onCancel — return partial output.
            logger.trace("shell-drain-cancellation-caught", metadata: [
              "shell_id": "\(id)", "pid": "\(pid)",
              "drain_elapsed_us": "\(tDrain.duration(to: .now).microseconds)",
            ])
            result = (pid, 0, 0)
          } catch {
            logger.trace("shell-drain-error", metadata: [
              "shell_id": "\(id)", "pid": "\(pid)",
              "error": "\(String(describing: error))",
              "drain_elapsed_us": "\(tDrain.duration(to: .now).microseconds)",
            ])
            throw error
          }

          try? stdoutHandle.close()
          try? stderrHandle.close()
          logger.trace("shell-drain-handles-closed", metadata: [
            "shell_id": "\(id)", "pid": "\(pid)",
          ])
          return result
        } onCancel: {
          let tCancel = ContinuousClock.now
          logger.trace("shell-onCancel-fired", metadata: [
            "shell_id": "\(id)", "pid": "\(pid)",
            "elapsed_since_entry_us": "\(tCancel.duration(to: t0).microseconds)",
          ])

          // Slam file handles shut so any in-flight write throws immediately.
          logger.trace("shell-onCancel-closing-handles", metadata: ["shell_id": "\(id)"])
          try? stdoutHandle.close()
          try? stderrHandle.close()
          logger.trace("shell-onCancel-handles-closed", metadata: ["shell_id": "\(id)"])

          do {
            #if os(Windows)
            logger.trace("shell-onCancel-kill-windows", metadata: ["shell_id": "\(id)", "pid": "\(pid)"])
            try execution.terminate(withExitCode: 0)
            logger.trace("shell-onCancel-kill-windows-ok", metadata: ["shell_id": "\(id)"])
            #elseif os(Linux)
            logger.trace("shell-onCancel-kill-tree-start", metadata: ["shell_id": "\(id)", "pid": "\(pid)"])
            let tKill = ContinuousClock.now
            let killed = Self.killProcessTree(pid: pid, id: id.uuidString)
            let killUs = tKill.duration(to: .now).microseconds
            logger.trace("shell-onCancel-kill-tree-done", metadata: [
              "shell_id": "\(id)", "pid": "\(pid)",
              "killed_count": "\(killed)", "kill_elapsed_us": "\(killUs)",
            ])
            #else
            logger.trace("shell-onCancel-kill-pgrp", metadata: ["shell_id": "\(id)", "pid": "\(pid)"])
            try execution.send(signal: .kill, toProcessGroup: true)
            logger.trace("shell-onCancel-kill-pgrp-ok", metadata: ["shell_id": "\(id)"])
            #endif
          } catch {
            logger.trace("shell-onCancel-kill-failed", metadata: [
              "shell_id": "\(id)", "pid": "\(pid)",
              "error": "\(String(describing: error))",
            ])
          }
          logger.trace("shell-onCancel-complete", metadata: [
            "shell_id": "\(id)",
            "onCancel_elapsed_us": "\(tCancel.duration(to: .now).microseconds)",
          ])
        }
      }
    } catch {
      logger.trace("shell-subprocess-run-threw", metadata: [
        "shell_id": "\(id)", "error": "\(String(describing: error))",
        "total_elapsed_us": "\(t0.duration(to: .now).microseconds)",
      ])
      throw error
    }

    let tEnd = ContinuousClock.now
    let totalUs = t0.duration(to: tEnd).microseconds
    let outSize = fileSize(url: stdoutURL)
    let errSize = fileSize(url: stderrURL)
    logger.trace(
      "shell-run-returning",
      metadata: [
        "shell_id": "\(id)",
        "pid": "\(outcome.value.0)",
        "termination": "\(String(describing: outcome.terminationStatus))",
        "out_bytes": "\(outcome.value.1)",
        "err_bytes": "\(outcome.value.2)",
        "out_file_bytes": "\(outSize)",
        "err_file_bytes": "\(errSize)",
        "total_elapsed_us": "\(totalUs)",
      ])
    return Result(
      exitCode: outcome.terminationStatus,
      stdoutFile: stdoutPath,
      stderrFile: stderrPath,
      pid: outcome.value.0
    )
  }

  // MARK: - Process tree kill (Linux)

  #if os(Linux)
  /// Recursively kills `pid` and all its descendants by walking `/proc`.
  /// Returns the total number of processes signalled (including the root).
  private static func killProcessTree(pid: pid_t, id: String) -> Int {
    var pids = [pid]
    // Collect all descendants recursively via /proc/[pid]/task/[tid]/children.
    var i = 0
    while i < pids.count {
      let current = pids[i]
      if let children = readChildPids(of: current) {
        for child in children where child > 2 {  // skip PID 1 (init) and PID 2 (kthreadd)
          if !pids.contains(child) {
            pids.append(child)
          }
        }
      }
      i += 1
    }
    logger.trace("kill-tree-collected", metadata: [
      "shell_id": "\(id)", "root_pid": "\(pid)", "total_pids": "\(pids.count)",
      "pids": "\(pids.map { String($0) }.joined(separator: ","))",
    ])
    // Kill from leaves to root (reverse order).
    var killed = 0
    for victim in pids.reversed() {
      if kill(victim, SIGKILL) == 0 {
        killed += 1
      } else {
        let e = errno
        if e != ESRCH {
          logger.trace("kill-tree-single-failed", metadata: [
            "shell_id": "\(id)", "pid": "\(victim)", "errno": "\(e)",
          ])
        }
      }
    }
    return killed
  }

  /// Reads the set of direct child PIDs from `/proc/[pid]/task/[pid]/children`.
  private static func readChildPids(of pid: pid_t) -> [pid_t]? {
    let path = "/proc/\(pid)/task/\(pid)/children"
    guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
      return nil
    }
    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    return trimmed.split(separator: " ").compactMap { pid_t($0) }
  }
  #endif

  // MARK: - Stream to file

  /// Writes all chunks from an `AsyncBufferSequence` to a file handle, returning the total byte count.
  /// The caller owns the handle and must close it.
  private static func writeStream(
    from sequence: AsyncBufferSequence,
    to handle: FileHandle,
    label: String,
    pid: pid_t,
    shellID: UUID
  ) async throws -> Int {
    let t0 = ContinuousClock.now
    var totalBytes = 0
    var chunkCount = 0
    let maxChunks = 1_000_000
    // Log a heartbeat every N chunks so we can see if the stream is alive.
    let heartbeatInterval = 1000

    logger.trace("write-stream-entry", metadata: [
      "shell_id": "\(shellID)", "stream": "\(label)", "pid": "\(pid)",
      "cancelled": "\(Task.isCancelled)",
    ])

    for try await buffer in sequence {
      // Record how long we waited for this chunk (helps detect hangs).
      let waitUs = t0.duration(to: .now).microseconds
      if chunkCount == 0 {
        logger.trace("write-stream-first-chunk-arrived", metadata: [
          "shell_id": "\(shellID)", "stream": "\(label)",
          "bytes": "\(buffer.count)", "wait_us": "\(waitUs)",
          "cancelled": "\(Task.isCancelled)",
        ])
      }

      try Task.checkCancellation()
      chunkCount += 1
      totalBytes += buffer.count

      // Periodic heartbeat — proves we're still processing, not stuck.
      if chunkCount % heartbeatInterval == 0 {
        logger.trace("write-stream-heartbeat", metadata: [
          "shell_id": "\(shellID)", "stream": "\(label)",
          "chunks": "\(chunkCount)", "total_bytes": "\(totalBytes)",
          "elapsed_us": "\(waitUs)",
          "cancelled": "\(Task.isCancelled)",
        ])
      }

      try handle.write(contentsOf: Data(buffer: buffer))

      if chunkCount >= maxChunks {
        logger.warning("write-stream-chunk-cap-hit", metadata: [
          "shell_id": "\(shellID)", "stream": "\(label)",
          "chunks": "\(chunkCount)", "total_bytes": "\(totalBytes)",
        ])
        break
      }
    }

    let elapsedUs = t0.duration(to: .now).microseconds
    logger.trace("write-stream-exit", metadata: [
      "shell_id": "\(shellID)", "stream": "\(label)",
      "chunks": "\(chunkCount)", "total_bytes": "\(totalBytes)",
      "elapsed_us": "\(elapsedUs)",
      "cancelled_at_exit": "\(Task.isCancelled)",
      "exit_reason": Task.isCancelled ? "cancelled" : (chunkCount >= maxChunks ? "cap" : "eof"),
    ])
    return totalBytes
  }

  // MARK: - Helpers

  private static func fileSize(url: URL) -> Int64 {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? -1
  }
}

extension Duration {
  var microseconds: Int64 {
    let (seconds, attoseconds) = self.components
    return seconds * 1_000_000 + attoseconds / 1_000_000_000_000
  }
}
