import Foundation
import Logging
import Subprocess

// Set by the CLI layer at session start so all tool/shell logs route to the session file.
// TODO: Address logging mess.
package nonisolated(unsafe) var scribeSessionLogger: Logger?

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

  private static let defaultLogger = Logger(label: "scribe.tool.shell")
  private static var logger: Logger { scribeSessionLogger ?? defaultLogger }

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

    // Log entry immediately — before any filesystem work — so we can confirm
    // Shell.run was reached even when logs aren't flushed later.
    logger.trace(
      "shell-run-entry",
      metadata: [
        "shell_id": "\(id)", "command": "\(trimmed.logSafe())",
        "cancelled_at_entry": "\(Task.isCancelled)",
      ])

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
      "shell-tempfiles-ready",
      metadata: [
        "shell_id": "\(id)",
        "stdout_file": "\(stdoutURL.path)", "stderr_file": "\(stderrURL.path)",
      ])

    // Open file handles up front so onCancel can close them as a safety net.
    guard let stdoutHandle = try? FileHandle(forWritingTo: stdoutURL),
      let stderrHandle = try? FileHandle(forWritingTo: stderrURL)
    else {
      logger.error("shell-handle-open-failed", metadata: ["shell_id": "\(id)"])
      throw ShellError(description: "could not open temp files for writing")
    }

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
        .path(ScribeFilePath("/bin/sh")),
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

          // Detach the drain so it can outlive parent-task cancellation. We
          // explicitly bound the post-cancel wait via `awaitDrainWithDeadline`
          // below; if a setsid grandchild keeps the subprocess stdout pipe
          // open after SIGKILL, the deadline fires and we settle for whatever
          // partial output is on disk instead of hanging this task forever.
          let drainTask = Task.detached(priority: .userInitiated) {
            [outputSequence, errorSequence, stdoutHandle, stderrHandle, id, pid]
            () async throws -> (Int, Int) in
            async let out = Self.writeStream(
              from: outputSequence, to: stdoutHandle,
              label: "\(id)/stdout", pid: pid, shellID: id)
            async let err = Self.writeStream(
              from: errorSequence, to: stderrHandle,
              label: "\(id)/stderr", pid: pid, shellID: id)
            return try await (out, err)
          }

          let result: (pid_t, Int, Int)
          do {
            let r = try await drainTask.value
            result = (pid, r.0, r.1)
            logger.trace(
              "shell-drain-complete",
              metadata: [
                "shell_id": "\(id)", "pid": "\(pid)",
                "out_bytes": "\(result.1)", "err_bytes": "\(result.2)",
                "drain_elapsed_us": "\(tDrain.duration(to: ContinuousClock.now).microseconds)",
                "cancelled": "\(Task.isCancelled)",
              ])
          } catch is CancellationError {
            // Parent cancelled mid-drain. The kill in onCancel should have
            // SIGKILL'd the subprocess, so the pipes should EOF momentarily
            // and the detached drain should return naturally. Race the drain
            // against a hard deadline so a surviving setsid grandchild that
            // keeps the pipe open can't hang us indefinitely.
            //
            // The race itself runs in a fresh detached task so it isn't
            // subject to the calling task's now-sticky cancellation flag
            // (which would otherwise make Task.sleep throw immediately and
            // collapse the deadline to zero).
            let bytes = await Self.awaitDrainWithDeadline(
              drainTask: drainTask, deadlineMs: 2_000, shellID: id)
            if let bytes {
              result = (pid, bytes.out, bytes.err)
              logger.trace(
                "shell-drain-completed-after-cancel",
                metadata: [
                  "shell_id": "\(id)", "pid": "\(pid)",
                  "out_bytes": "\(bytes.out)", "err_bytes": "\(bytes.err)",
                  "drain_elapsed_us": "\(tDrain.duration(to: .now).microseconds)",
                ])
            } else {
              try? stdoutHandle.close()
              try? stderrHandle.close()
              let outSize = Int(fileSize(url: stdoutURL))
              let errSize = Int(fileSize(url: stderrURL))
              logger.trace(
                "shell-drain-deadline-reached",
                metadata: [
                  "shell_id": "\(id)", "pid": "\(pid)",
                  "drain_elapsed_us": "\(tDrain.duration(to: .now).microseconds)",
                  "out_bytes_on_disk": "\(outSize)", "err_bytes_on_disk": "\(errSize)",
                ])
              result = (pid, outSize, errSize)
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

          try? stdoutHandle.close()
          try? stderrHandle.close()
          logger.trace(
            "shell-drain-handles-closed",
            metadata: [
              "shell_id": "\(id)", "pid": "\(pid)",
            ])
          return result
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
          //
          // Previously this also spawned an unstructured `Task { sleep
          // 500ms; close handles }` as a safety net. That was removed:
          //   1. Closing the *write* side of the temp file does nothing
          //      to unblock the *read* side of the subprocess stdout
          //      pipe owned by swift-subprocess, so it never actually
          //      saved a hanging drain.
          //   2. Each interrupted shell left an orphan Task on the
          //      cooperative pool holding two FileHandle references for
          //      ≥500 ms, which under repeated Ctrl-C accumulated FDs
          //      and contributed to the spin reports.
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
            logger.trace(
              "shell-onCancel-kill-tree-done",
              metadata: [
                "shell_id": "\(id)", "pid": "\(pid)",
                "killed_count": "\(killed)", "kill_elapsed_us": "\(killUs)",
              ])
            #else
            logger.trace("shell-onCancel-kill-pgrp", metadata: ["shell_id": "\(id)", "pid": "\(pid)"])
            try execution.send(signal: .kill, toProcessGroup: true)
            logger.trace("shell-onCancel-kill-pgrp-ok", metadata: ["shell_id": "\(id)"])
            #endif
          } catch {
            logger.trace(
              "shell-onCancel-kill-failed",
              metadata: [
                "shell_id": "\(id)", "pid": "\(pid)",
                "error": "\(String(describing: error))",
              ])
          }

          logger.trace(
            "shell-onCancel-complete",
            metadata: [
              "shell_id": "\(id)",
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
    logger.trace(
      "kill-tree-collected",
      metadata: [
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
          logger.trace(
            "kill-tree-single-failed",
            metadata: [
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

  // MARK: - Drain deadline

  /// Bytes counted off each pipe by a successful drain.
  private struct DrainBytes: Sendable {
    let out: Int
    let err: Int
  }

  /// Race a detached drain task against a fixed deadline.  Returns the
  /// drain's byte counts when the drain completes first, or `nil` when the
  /// deadline fires (in which case the caller should close handles and
  /// settle for whatever's already on disk).
  ///
  /// The race itself runs in a fresh detached task so it isn't subject to
  /// the calling task's cancellation state — otherwise `Task.sleep` would
  /// throw immediately on a cancelled parent and collapse the deadline.
  private static func awaitDrainWithDeadline(
    drainTask: Task<(Int, Int), Error>,
    deadlineMs: Int,
    shellID: UUID
  ) async -> DrainBytes? {
    enum RaceOutcome: Sendable {
      case completed(out: Int, err: Int)
      case deadline
      case errored
    }
    return await Task.detached(priority: .userInitiated) {
      [drainTask] () async -> DrainBytes? in
      await withTaskGroup(of: RaceOutcome.self) { group in
        group.addTask {
          do {
            let r = try await drainTask.value
            return .completed(out: r.0, err: r.1)
          } catch {
            return .errored
          }
        }
        group.addTask {
          try? await Task.sleep(for: .milliseconds(deadlineMs))
          return .deadline
        }
        let first = await group.next()!
        group.cancelAll()
        switch first {
        case .completed(let out, let err):
          return DrainBytes(out: out, err: err)
        case .deadline:
          // Try to push the drain to exit; the parent will fall back to
          // disk-side byte counts regardless.
          drainTask.cancel()
          Self.logger.trace(
            "shell-drain-deadline-fired",
            metadata: [
              "shell_id": "\(shellID)", "deadline_ms": "\(deadlineMs)",
            ])
          return nil
        case .errored:
          return nil
        }
      }
    }.value
  }

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

    logger.trace(
      "write-stream-entry",
      metadata: [
        "shell_id": "\(shellID)", "stream": "\(label)", "pid": "\(pid)",
        "cancelled": "\(Task.isCancelled)",
      ])

    // Once `stopWriting` flips we keep iterating the producer's sequence so
    // the underlying pipe drains — otherwise the subprocess blocks on its
    // next stdout write, the AsyncBufferSequence never EOFs, and a
    // SIGKILL'd process can leave this drain hanging forever (one of the
    // suspected sources of the historical 100% CPU spin reports).
    // Cancellation is the only signal that breaks out hard, since by then
    // onCancel has already SIGKILL'd the process tree.
    var stopWriting = false
    var stopReason = "eof"

    for try await buffer in sequence {
      let waitUs = t0.duration(to: .now).microseconds
      if chunkCount == 0 {
        logger.trace(
          "write-stream-first-chunk-arrived",
          metadata: [
            "shell_id": "\(shellID)", "stream": "\(label)",
            "bytes": "\(buffer.count)", "wait_us": "\(waitUs)",
            "cancelled": "\(Task.isCancelled)",
          ])
      }

      chunkCount += 1

      if chunkCount % heartbeatInterval == 0 {
        logger.trace(
          "write-stream-heartbeat",
          metadata: [
            "shell_id": "\(shellID)", "stream": "\(label)",
            "chunks": "\(chunkCount)", "total_bytes": "\(totalBytes)",
            "elapsed_us": "\(waitUs)",
            "cancelled": "\(Task.isCancelled)",
            "stop_writing": "\(stopWriting)",
          ])
      }

      if !stopWriting {
        do {
          try handle.write(contentsOf: Data(buffer: buffer))
          totalBytes += buffer.count
        } catch {
          logger.trace(
            "write-stream-write-failed",
            metadata: [
              "shell_id": "\(shellID)", "stream": "\(label)",
              "error": "\(String(describing: error))",
              "chunks_written": "\(chunkCount - 1)",
              "bytes_before_failure": "\(totalBytes)",
            ])
          stopWriting = true
          stopReason = "write-failed"
        }
      }

      if !stopWriting && chunkCount == maxChunks {
        logger.warning(
          "write-stream-chunk-cap-hit",
          metadata: [
            "shell_id": "\(shellID)", "stream": "\(label)",
            "chunks": "\(chunkCount)", "total_bytes": "\(totalBytes)",
          ])
        stopWriting = true
        stopReason = "cap"
      }

      if Task.isCancelled {
        logger.trace(
          "write-stream-cancelled",
          metadata: [
            "shell_id": "\(shellID)", "stream": "\(label)",
            "chunks": "\(chunkCount)", "total_bytes": "\(totalBytes)",
          ])
        stopReason = "cancelled"
        break
      }
    }

    let elapsedUs = t0.duration(to: .now).microseconds
    logger.trace(
      "write-stream-exit",
      metadata: [
        "shell_id": "\(shellID)", "stream": "\(label)",
        "chunks": "\(chunkCount)", "total_bytes": "\(totalBytes)",
        "elapsed_us": "\(elapsedUs)",
        "cancelled_at_exit": "\(Task.isCancelled)",
        "exit_reason": "\(stopReason)",
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
