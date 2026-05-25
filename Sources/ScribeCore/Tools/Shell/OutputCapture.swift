import Foundation
import Logging
import Subprocess
import SystemPackage

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

struct OutputCapture: Sendable {

  let id: UUID
  let stdoutFile: FilePath
  let stderrFile: FilePath

  let stdoutURL: URL
  let stderrURL: URL

  let stdoutHandle: FileHandle
  let stderrHandle: FileHandle

  static func create(id: UUID, in tmpDir: URL) throws -> OutputCapture {
    let stdoutURL = tmpDir.appendingPathComponent(
      "scribe-shell-\(id.uuidString)-stdout.txt")
    let stderrURL = tmpDir.appendingPathComponent(
      "scribe-shell-\(id.uuidString)-stderr.txt")

    try "".write(to: stdoutURL, atomically: false, encoding: .utf8)
    try "".write(to: stderrURL, atomically: false, encoding: .utf8)

    guard let stdoutHandle = try? FileHandle(forWritingTo: stdoutURL),
      let stderrHandle = try? FileHandle(forWritingTo: stderrURL)
    else {
      throw Shell.ShellError(description: "could not open temp files for writing")
    }

    return OutputCapture(
      id: id,
      stdoutFile: FilePath(stdoutURL.path),
      stderrFile: FilePath(stderrURL.path),
      stdoutURL: stdoutURL,
      stderrURL: stderrURL,
      stdoutHandle: stdoutHandle,
      stderrHandle: stderrHandle
    )
  }

  func closeHandles() {
    try? stdoutHandle.close()
    try? stderrHandle.close()
  }

  func diskSizes() -> DrainBytes {
    DrainBytes(
      out: Int(Self.fileSize(url: stdoutURL)),
      err: Int(Self.fileSize(url: stderrURL))
    )
  }

  func startDrain(
    stdout: AsyncBufferSequence,
    stderr: AsyncBufferSequence,
    pid: pid_t,
    logger: Logger
  ) -> Task<DrainBytes, Error> {
    Task.detached(priority: .userInitiated) {
      [stdout, stderr, stdoutHandle, stderrHandle, id, pid] in
      async let out = Self.writeStream(
        from: stdout, to: stdoutHandle,
        label: "\(id)/stdout", pid: pid, shellID: id, logger: logger)
      async let err = Self.writeStream(
        from: stderr, to: stderrHandle,
        label: "\(id)/stderr", pid: pid, shellID: id, logger: logger)
      let (o, e) = try await (out, err)
      return DrainBytes(out: o, err: e)
    }
  }

  static func awaitDrainWithDeadline(
    drainTask: Task<DrainBytes, Error>,
    deadlineMs: Int,
    shellID: UUID,
    logger: Logger
  ) async -> DrainBytes? {
    enum RaceOutcome: Sendable {
      case completed(DrainBytes)
      case deadline
      case errored
    }
    return await Task.detached(priority: .userInitiated) {
      [drainTask] () async -> DrainBytes? in
      await withTaskGroup(of: RaceOutcome.self) { group in
        group.addTask {
          do {
            return .completed(try await drainTask.value)
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
        case .completed(let bytes):
          return bytes
        case .deadline:
          drainTask.cancel()
          logger.trace(
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

  static func writeStream(
    from sequence: AsyncBufferSequence,
    to handle: FileHandle,
    label: String,
    pid: pid_t,
    shellID: UUID,
    logger: Logger
  ) async throws -> Int {
    let t0 = ContinuousClock.now
    var totalBytes = 0
    var chunkCount = 0
    let maxChunks = 1_000_000
    let heartbeatInterval = 1000

    logger.trace(
      "write-stream-entry",
      metadata: [
        "shell_id": "\(shellID)", "stream": "\(label)", "pid": "\(pid)",
        "cancelled": "\(Task.isCancelled)",
      ])

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

  private static func fileSize(url: URL) -> Int64 {
    FileStat.fileSize(FilePath(url.path))
  }
}

struct DrainBytes: Sendable {
  let out: Int
  let err: Int
}
