import Logging
import Synchronization

final class LogRecorder: Sendable {
  struct Entry: Sendable {
    let message: String
    let metadata: Logger.Metadata
  }

  let entries = Mutex<[Entry]>([])

  func logger() -> Logger {
    Logger(label: "test.responses-diagnostics") { _ in RecordingLogHandler(recorder: self) }
  }
}

private struct RecordingLogHandler: LogHandler {
  let recorder: LogRecorder
  var logLevel: Logger.Level = .trace
  var metadata: Logger.Metadata = [:]

  subscript(metadataKey key: String) -> Logger.Metadata.Value? {
    get { metadata[key] }
    set { metadata[key] = newValue }
  }

  func log(event: LogEvent) {
    let merged = metadata.merging(event.metadata ?? [:]) { _, value in value }
    recorder.entries.withLock { $0.append(.init(message: event.message.description, metadata: merged)) }
  }
}
