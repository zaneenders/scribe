import Foundation
import Logging
import Synchronization
import SystemPackage

/// Serializes session log writes to a file, degrading to stderr on open or I/O failure.
private final class SessionLogWriteBackend: Sendable {
  private let fileWriter = Mutex<AppendOnlyFileWriter?>(nil)
  private let warned = Mutex(false)

  init(logFile: FilePath) {
    fileWriter.withLock { slot in
      slot = try? AppendOnlyFileWriter(filePath: logFile)
    }
  }

  func write(_ data: Data) {
    let outcome = fileWriter.withLock { slot -> Result<Void, Error>? in
      guard let writer = slot else { return nil }
      do {
        try writer.append(data)
        return .success(())
      } catch {
        slot = nil
        return .failure(error)
      }
    }
    switch outcome {
    case .success:
      return
    case .failure(let error):
      if warned.withLock({ alreadyWarned in
        if alreadyWarned { return false }
        alreadyWarned = true
        return true
      }) {
        let line =
          "scribe: session log write failed (\(error.localizedDescription)); further lines go to stderr\n"
        try? FileHandle.standardError.write(contentsOf: Data(line.utf8))
      }
      try? FileHandle.standardError.write(contentsOf: data)
    case nil:
      try? FileHandle.standardError.write(contentsOf: data)
    }
  }
}

/// Builds per-invocation loggers for the CLI (append-only file under the session directory).
enum SessionLoggerFactory {

  /// Appends to the given log file (creates parent directories and file if needed).
  /// Falls back to stderr when the file cannot be opened or after the first write failure.
  /// Sets `session_id` on the returned logger for all subsequent lines.
  static func makeSessionLogger(
    sessionId: UUID,
    minimumLevel: Logger.Level,
    logFile: FilePath
  ) -> Logger {
    let backend = SessionLogWriteBackend(logFile: logFile)
    let dataWriter = LockedDataWriter { data in
      backend.write(data)
    }
    var sessionLogger = Logger(label: "scribe.session") { _ in
      ScribeLineLogHandler(minimumLevel: minimumLevel, dataWriter: dataWriter)
    }
    sessionLogger[metadataKey: "session_id"] = "\(sessionId.uuidString)"
    return sessionLogger
  }
}
