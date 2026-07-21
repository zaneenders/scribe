import Foundation
import Logging
import Synchronization
import SystemPackage

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

public enum SessionLoggerFactory {

  public static func makeSessionLogger(
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
