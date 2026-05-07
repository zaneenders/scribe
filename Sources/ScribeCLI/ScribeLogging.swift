import Foundation
import Logging
import Synchronization

/// A globally-swappable log data writer so per-session log files can be set up
/// after `LoggingSystem` is bootstrapped.  Call `swap(to:)` once the session
/// file is created; all `scribe.*` loggers start writing to it immediately.
public enum SharedLogWriter {
  private static let lock = Mutex<(writer: LockedDataWriter, level: Logger.Level)>(
    (LockedDataWriter { data in
      try? FileHandle.standardError.write(contentsOf: data)
    }, .trace))

  /// Replace the writer and log level for all `scribe.*` loggers.
  public static func swap(to writer: LockedDataWriter, level: Logger.Level) {
    lock.withLock { $0 = (writer, level) }
  }

  /// Write `data` through the currently-installed writer.
  public static func write(_ data: Data) {
    lock.withLock { $0.writer.write(data) }
  }

  /// The currently-configured minimum log level.
  public static var logLevel: Logger.Level {
    lock.withLock { $0.level }
  }
}

/// Bootstraps `LoggingSystem` so every `Logger` whose label starts with `scribe.`
/// (including `scribe.tool.shell`, `scribe.tool.registry`, etc.) routes through
/// `SharedLogWriter`.  Defaults to stderr until `swap(to:)` is called with a
/// session file writer.
///
/// Call this once at program start, before any `Logger` is created.
public func bootstrapScribeLogging() {
  LoggingSystem.bootstrap { label in
    guard label.hasPrefix("scribe.") || label == "scribe" else {
      return StreamLogHandler.standardError(label: label)
    }
    return SharedLogLineHandler(label: label)
  }
}

// MARK: - Timestamp formatter

private let timestampFormatter: Mutex<ISO8601DateFormatter> = {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return Mutex(formatter)
}()

// MARK: - Shared handler

private struct SharedLogLineHandler: LogHandler {
  let label: String
  var metadata: Logger.Metadata = [:]

  var logLevel: Logger.Level {
    get { SharedLogWriter.logLevel }
    set { /* no-op — level is driven by SharedLogWriter.swap() */ }
  }

  init(label: String) {
    self.label = label
  }

  func log(event: LogEvent) {
    var text = "\(event.message)"
    if let error = event.error {
      text += " err=\"\(error)\""
    }
    let timestamp = timestampFormatter.withLock { $0.string(from: Date()) }
    let line = "\(timestamp) [\(event.level.rawValue)] \(text)\n"
    SharedLogWriter.write(Data(line.utf8))
  }

  subscript(metadataKey metadataKey: String) -> Logger.Metadata.Value? {
    get { metadata[metadataKey] }
    set { metadata[metadataKey] = newValue }
  }
}
