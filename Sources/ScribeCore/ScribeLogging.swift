import Foundation
import Logging

/// Severity-ordered levels for `logging.level` in `scribe-config.json`.
///
/// A configured minimum level emits that level and all *more severe* levels (e.g. `info` also allows `notice`, `warning`, and `error`).
public enum ScribeLogLevel: String, Sendable, CaseIterable {
  case trace
  case debug
  case info
  case notice
  case warning
  case error

  public var priority: Int {
    switch self {
    case .trace: 0
    case .debug: 1
    case .info: 2
    case .notice: 3
    case .warning: 4
    case .error: 5
    }
  }

  /// Corresponding ``Logger/Level`` for swift-log (same raw strings).
  public var swiftLogLevel: Logger.Level {
    Logger.Level(rawValue: rawValue) ?? .info
  }

  init?(parsingConfig raw: String) {
    let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !s.isEmpty else { return nil }
    self.init(rawValue: s)
  }
}

// MARK: - swift-log handlers

final class LockedDataWriter: @unchecked Sendable {
  private let lock = NSLock()
  private let emit: @Sendable (Data) -> Void

  init(_ emit: @escaping @Sendable (Data) -> Void) {
    self.emit = emit
  }

  func write(_ data: Data) {
    lock.lock()
    defer { lock.unlock() }
    emit(data)
  }
}

final class FileSink: @unchecked Sendable {
  private let handle: FileHandle

  init(handle: FileHandle) {
    self.handle = handle
  }

  func write(_ data: Data) {
    try? handle.write(contentsOf: data)
    try? handle.synchronize()
  }

  deinit {
    try? handle.synchronize()
    try? handle.close()
  }
}

/// Writes `[scribe][level] …` lines; level filtering is performed by ``Logger`` before ``log(event:)`` is called.
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
      text += " — \(error)"
    }
    let line = "[scribe][\(event.level.rawValue)] \(text)\n"
    dataWriter.write(Data(line.utf8))
  }

  subscript(metadataKey metadataKey: String) -> Logger.Metadata.Value? {
    get { metadata[metadataKey] }
    set { metadata[metadataKey] = newValue }
  }
}

extension AgentConfig {
  /// Logs to standard error only (no per-request file). Suitable for startup and errors before a request session exists.
  public func makeStderrLogger() -> Logger {
    let level = logLevel.swiftLogLevel
    let writer = LockedDataWriter { data in
      try? FileHandle.standardError.write(contentsOf: data)
    }
    return Logger(label: "scribe") { _ in
      ScribeLineLogHandler(minimumLevel: level, dataWriter: writer)
    }
  }

  /// Logs to standard error and a new file under ``logDirectoryPath``; the file is closed when this logger is released.
  public func makeRequestLogger() -> Logger {
    let level = logLevel.swiftLogLevel
    try? FileManager.default.createDirectory(
      at: URL(fileURLWithPath: logDirectoryPath, isDirectory: true),
      withIntermediateDirectories: true
    )
    let fileURL = newRequestLogFileURL()
    FileManager.default.createFile(atPath: fileURL.path, contents: nil)
    guard let fileHandle = try? FileHandle(forWritingTo: fileURL) else {
      return makeStderrLogger()
    }
    let sink = FileSink(handle: fileHandle)
    let stderrWriter = LockedDataWriter { data in
      try? FileHandle.standardError.write(contentsOf: data)
    }
    let fileWriter = LockedDataWriter { data in sink.write(data) }
    return Logger(label: "scribe.request") { _ in
      var stderrHandler = ScribeLineLogHandler(minimumLevel: level, dataWriter: stderrWriter)
      stderrHandler.logLevel = level
      var fileHandler = ScribeLineLogHandler(minimumLevel: level, dataWriter: fileWriter)
      fileHandler.logLevel = level
      return MultiplexLogHandler([stderrHandler, fileHandler])
    }
  }

  private func newRequestLogFileURL() -> URL {
    let dir = URL(fileURLWithPath: logDirectoryPath, isDirectory: true)
    let token = "\(UInt64(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(8))"
    return dir.appendingPathComponent("scribe-\(token).log", isDirectory: false)
  }
}
