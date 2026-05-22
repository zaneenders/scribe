import Foundation
import Logging

/// Builds per-invocation loggers for the CLI (append-only file under the session directory).
enum SessionLoggerFactory {

  /// Appends to the given log file path (creates parent directories and file if needed).
  /// Sets `session_id` on the returned logger for all subsequent lines.
  static func makeSessionLogger(
    sessionId: UUID,
    minimumLevel: Logger.Level,
    logFilePath: String
  ) -> Logger {
    let fileURL = URL(fileURLWithPath: logFilePath, isDirectory: false)

    let writer: AppendOnlyFileWriter
    do {
      writer = try AppendOnlyFileWriter(fileURL: fileURL)
    } catch {
      fatalError(
        "Could not open session log at \(logFilePath): \(error.localizedDescription)")
    }

    let dataWriter = LockedDataWriter { data in
      try? writer.append(data)
    }
    var sessionLogger = Logger(label: "scribe.session") { _ in
      ScribeLineLogHandler(minimumLevel: minimumLevel, dataWriter: dataWriter)
    }
    sessionLogger[metadataKey: "session_id"] = "\(sessionId.uuidString)"
    return sessionLogger
  }
}
