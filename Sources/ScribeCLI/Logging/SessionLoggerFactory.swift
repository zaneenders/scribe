import Foundation
import Logging

/// Builds per-invocation loggers for the CLI (file under the session directory or stderr fallback).
enum SessionLoggerFactory {

  /// Appends to the given log file path (creates parent directories and file if needed).
  /// Sets `session_id` on the returned logger for all subsequent lines.
  static func makeSessionLogger(
    sessionId: UUID,
    minimumLevel: Logger.Level,
    logFilePath: String
  ) -> Logger {
    let fileURL = URL(fileURLWithPath: logFilePath, isDirectory: false)

    if let writer = try? AppendOnlyFileWriter(fileURL: fileURL) {
      let dataWriter = LockedDataWriter { data in
        try? writer.append(data)
      }
      var sessionLogger = Logger(label: "scribe.session") { _ in
        ScribeLineLogHandler(minimumLevel: minimumLevel, dataWriter: dataWriter)
      }
      sessionLogger[metadataKey: "session_id"] = "\(sessionId.uuidString)"
      return sessionLogger
    }

    var fallback = Logger(label: "scribe.session") { _ in
      ScribeLineLogHandler(
        minimumLevel: minimumLevel,
        dataWriter: LockedDataWriter { data in
          try? FileHandle.standardError.write(contentsOf: data)
        })
    }
    fallback[metadataKey: "session_id"] = "\(sessionId.uuidString)"
    return fallback
  }
}
