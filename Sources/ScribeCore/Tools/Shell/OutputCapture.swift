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

// MARK: - OutputCapture

/// Owns the per-invocation stdout/stderr temp files for a shell run plus
/// the drain task that pumps subprocess bytes into them. Encapsulates
/// three concerns that used to be inlined in `Shell.run`:
///
/// 1. **Temp file lifecycle** — paths, creation, handle ownership.
/// 2. **Drain orchestration** — concurrently iterating both `AsyncBufferSequence`s
///    and writing to disk, with a "drain-and-discard" mode that protects
///    against a stuck consumer hanging the producer pipe (suspect C from
///    the CPU-spin investigation).
/// 3. **Bounded post-cancellation wait** — racing the detached drain
///    against a fixed deadline so a `setsid` grandchild that keeps the
///    pipe open after `SIGKILL` can no longer hang the parent indefinitely
///    (suspect E).
///
/// `Shell.run` owns one `OutputCapture` per invocation. The capture is
/// `Sendable` so the detached drain task can hold onto it across
/// concurrency boundaries.
struct OutputCapture: Sendable {

  let id: UUID
  let stdoutFile: FilePath
  let stderrFile: FilePath

  /// Underlying URLs kept around so we can stat them for fallback byte
  /// counts when the drain misses its deadline.
  let stdoutURL: URL
  let stderrURL: URL

  let stdoutHandle: FileHandle
  let stderrHandle: FileHandle

  /// Build a fresh pair of temp files under the system temp dir and open
  /// write handles to each. Throws if the create or open step fails.
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

  /// Closes both file handles. Idempotent — safe to call after a partial
  /// drain or if the handles were never used.
  func closeHandles() {
    try? stdoutHandle.close()
    try? stderrHandle.close()
  }

  /// Returns the on-disk size of each temp file, used as a fallback when
  /// the in-memory drain counts are unavailable (deadline missed).
  func diskSizes() -> DrainBytes {
    DrainBytes(
      out: Int(Self.fileSize(url: stdoutURL)),
      err: Int(Self.fileSize(url: stderrURL))
    )
  }

  // MARK: Drain orchestration

  /// Spawns a `Task.detached` that iterates `stdout` and `stderr`
  /// concurrently and writes them to the temp files. Returns the task —
  /// the caller awaits it directly on the happy path or hands it to
  /// `awaitDrainWithDeadline` after cancellation.
  ///
  /// The detached task is intentional: the parent task may be cancelled
  /// while we still want the drain to keep emptying the subprocess pipes
  /// (so a `SIGKILL`'d process can EOF cleanly). If the drain is cancelled
  /// directly the writes still finish — `writeStream` only `break`s on
  /// `Task.isCancelled`, never on the parent's flag.
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

  /// Race a detached drain task against a fixed deadline.  Returns the
  /// drain's byte counts when the drain completes first, or `nil` when
  /// the deadline fires (in which case the caller should close handles
  /// and read sizes from disk via `diskSizes()`).
  ///
  /// The race itself runs in a fresh detached task so it isn't subject
  /// to the calling task's cancellation state — otherwise `Task.sleep`
  /// would throw immediately on a cancelled parent and collapse the
  /// deadline to zero.
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

  // MARK: writeStream

  /// Drain a single `AsyncBufferSequence` to a `FileHandle`, returning
  /// the byte count actually written. The "drain and discard" pattern
  /// (suspect C) is critical here: once the disk write fails or we hit
  /// the chunk cap, we keep pulling from the sequence so the underlying
  /// pipe stays drained — otherwise the producer subprocess blocks on
  /// its next stdout write, the sequence never EOFs, and a SIGKILL'd
  /// process can leave this drain hanging forever.
  ///
  /// `Task.isCancelled` is the only signal that breaks out hard. By the
  /// time it flips, `onCancel` has already SIGKILL'd the process tree.
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
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? -1
  }
}

// MARK: - DrainBytes

/// Stdout/stderr byte counts returned by a completed drain.
struct DrainBytes: Sendable {
  let out: Int
  let err: Int
}
