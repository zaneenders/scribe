import Foundation
import Logging
import Subprocess
import _RopeModule

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
    let stdout: String
    let stderr: String
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

    logger.trace(
      "starting", metadata: ["shell_id": "\(id)", "command": "\(command)", "cwd": "\(workingDirectory ?? "nil")"])

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
      let pid = execution.processIdentifier.value
      logger.trace("spawned", metadata: ["shell_id": "\(id)", "pid": "\(pid)"])
      logger.trace("registering-cancellation-handler", metadata: ["shell_id": "\(id)", "pid": "\(pid)"])
      return try await withTaskCancellationHandler {
        logger.trace("draining-streams-start", metadata: ["shell_id": "\(id)", "pid": "\(pid)"])
        // Collect stdout and stderr concurrently.
        async let out = collectString(from: outputSequence, label: "\(id)/stdout", pid: pid)
        async let err = collectString(from: errorSequence, label: "\(id)/stderr", pid: pid)
        let result = try await (pid, out, err)
        logger.trace(
          "draining-streams-end",
          metadata: [
            "shell_id": "\(id)", "pid": "\(pid)", "out_chars": "\(result.1.count)", "err_chars": "\(result.2.count)",
          ])
        return result
      } onCancel: {
        logger.trace("onCancel-fired", metadata: ["shell_id": "\(id)", "pid": "\(pid)"])
        do {
          #if os(Windows)
          logger.trace("sending-Windows-terminate", metadata: ["shell_id": "\(id)", "pid": "\(pid)"])
          try execution.terminate(withExitCode: 0)
          logger.trace("Windows-terminate-succeeded", metadata: ["shell_id": "\(id)", "pid": "\(pid)"])
          #elseif os(Linux)
          // swiftc creates its own process groups on Linux, so a simple
          // kill(-pgid) misses compiler children.  Walk /proc to recursively
          // kill every descendant regardless of process group.
          logger.trace("killing-process-tree-start", metadata: ["shell_id": "\(id)", "pid": "\(pid)"])
          let killed = Self.killProcessTree(pid: pid, id: id.uuidString)
          logger.trace("process-tree-killed", metadata: ["shell_id": "\(id)", "pid": "\(pid)", "count": "\(killed)"])
          #else
          // macOS / other Unix: process-group kill is sufficient.
          logger.trace("sending-SIGKILL-to-process-group", metadata: ["shell_id": "\(id)", "pid": "\(pid)"])
          try execution.send(signal: .kill, toProcessGroup: true)
          logger.trace("SIGKILL-succeeded", metadata: ["shell_id": "\(id)", "pid": "\(pid)"])
          #endif
        } catch {
          logger.trace(
            "process-kill-failed",
            metadata: ["shell_id": "\(id)", "pid": "\(pid)", "err": "\(String(describing: error))"])
        }
      }
    }

    logger.trace(
      "run-returning",
      metadata: [
        "shell_id": "\(id)",
        "pid": "\(outcome.value.0)",
        "termination": "\(String(describing: outcome.terminationStatus))",
        "out_chars": "\(outcome.value.1.count)",
        "err_chars": "\(outcome.value.2.count)",
      ])
    return Result(
      exitCode: outcome.terminationStatus,
      stdout: String(outcome.value.1),
      stderr: String(outcome.value.2),
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
    // Kill from leaves to root (reverse order).
    var killed = 0
    for victim in pids.reversed() {
      if kill(victim, SIGKILL) == 0 {
        killed += 1
        logger.trace("process-tree-kill", metadata: ["shell_id": "\(id)", "pid": "\(victim)", "status": "ok"])
      } else {
        let e = errno
        // ESRCH: already exited, EPERM: not ours (shouldn't happen).
        if e != ESRCH {
          logger.trace(
            "process-tree-kill",
            metadata: ["shell_id": "\(id)", "pid": "\(victim)", "status": "failed", "errno": "\(e)"])
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

  private static func collectString(
    from sequence: AsyncBufferSequence,
    label: String,
    pid: pid_t
  ) async throws -> BigString {
    var result = BigString()
    var chunkCount = 0
    var totalBytes = 0
    for try await buffer in sequence {
      chunkCount += 1
      totalBytes += buffer.count
      if chunkCount == 1 {
        logger.trace("first-chunk", metadata: ["stream": "\(label)", "pid": "\(pid)", "bytes": "\(buffer.count)"])
      }
      result.append(
        contentsOf: buffer.withUnsafeBytes { raw in
          String(decoding: raw, as: UTF8.self)
        })
    }
    logger.trace(
      "collect-done",
      metadata: [
        "stream": "\(label)",
        "pid": "\(pid)",
        "chunks": "\(chunkCount)",
        "total_bytes": "\(totalBytes)",
        "result_chars": "\(result.count)",
      ])
    return result
  }
}
