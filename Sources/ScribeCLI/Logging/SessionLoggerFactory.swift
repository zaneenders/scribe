import Foundation
import Logging
import SystemPackage

/// Builds per-invocation loggers for the CLI (append-only file under the session directory).
enum SessionLoggerFactory {

  /// Appends to the given log file (creates parent directories and file if needed).
  /// Sets `session_id` on the returned logger for all subsequent lines.
  static func makeSessionLogger(
    sessionId: UUID,
    minimumLevel: Logger.Level,
    logFile: FilePath
  ) -> Logger {
    let writer: AppendOnlyFileWriter
    do {
      writer = try AppendOnlyFileWriter(filePath: logFile)
    } catch {
      fatalError(
        "Could not open session log at \(logFile.string): \(error.localizedDescription)")
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
