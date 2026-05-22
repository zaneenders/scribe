import Foundation
import Logging
import Synchronization

/// Lock-protected `ISO8601DateFormatter` reused from concurrent log calls.
private let scribeLogTimestampFormatter: Mutex<ISO8601DateFormatter> = {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return Mutex(formatter)
}()

/// Formats each log line as
/// `<iso8601-ms> [<level>] <message> key=value …`
/// using swift-log metadata (logger-level + per-call), sorted for stable grep.
struct ScribeLineLogHandler: LogHandler {
  var logLevel: Logger.Level = .info
  var metadata: Logger.Metadata = [:]

  private let dataWriter: LockedDataWriter

  init(minimumLevel: Logger.Level, dataWriter: LockedDataWriter) {
    self.logLevel = minimumLevel
    self.dataWriter = dataWriter
  }

  func log(event: LogEvent) {
    var text = "\(event.message)"
    if let error = event.error {
      text += " err=\"\(error)\""
    }
    var merged = self.metadata
    if let eventMeta = event.metadata {
      for (key, value) in eventMeta {
        merged[key] = value
      }
    }
    if !merged.isEmpty {
      let pairs = merged.map { key, value in
        "\(key)=\(value)"
      }.sorted().joined(separator: " ")
      text += " \(pairs)"
    }
    let timestamp = scribeLogTimestampFormatter.withLock { $0.string(from: Date()) }
    let line = "\(timestamp) [\(event.level.rawValue)] \(text)\n"
    dataWriter.write(Data(line.utf8))
  }

  subscript(metadataKey metadataKey: String) -> Logger.Metadata.Value? {
    get { metadata[metadataKey] }
    set { metadata[metadataKey] = newValue }
  }
}
