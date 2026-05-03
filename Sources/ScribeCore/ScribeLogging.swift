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

/// Lock-protected wrapper around `ISO8601DateFormatter` so a single shared instance can be
/// reused from many tasks under strict concurrency. ``ISO8601DateFormatter`` does not conform
/// to `Sendable`; serializing access here keeps the format string cached without paying the
/// per-call setup cost on every log line.
private final class ScribeLogTimestampFormatter: @unchecked Sendable {
  private let lock = NSLock()
  private let inner: ISO8601DateFormatter

  init() {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    self.inner = f
  }

  func string(from date: Date) -> String {
    lock.lock()
    defer { lock.unlock() }
    return inner.string(from: date)
  }
}

private let scribeLogTimestampFormatter = ScribeLogTimestampFormatter()

/// One log line per call, formatted as
/// `<iso8601-ms> [<level>] <message>` so each line is timestamped and easy to grep,
/// and message bodies are expected to use the structured `event=ns.name k=v k=v` style
/// described in `docs/chat-input-behavior.md`.
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
    let timestamp = scribeLogTimestampFormatter.string(from: Date())
    let line = "\(timestamp) [\(event.level.rawValue)] \(text)\n"
    dataWriter.write(Data(line.utf8))
  }

  subscript(metadataKey metadataKey: String) -> Logger.Metadata.Value? {
    get { metadata[metadataKey] }
    set { metadata[metadataKey] = newValue }
  }
}

extension AgentConfig {
  /// Returns a logger appending all events for one Scribe invocation to
  /// ``logDirectoryPath``/`scribe-{sessionId}.log`. Pass the chat session id when one exists
  /// (so the log file shares a UUID stem with the matching `{uuid}.json` transcript archive),
  /// or a freshly-minted UUID for ephemeral / non-chat invocations (e.g. `runAgentIPC`).
  ///
  /// All Scribe events for a single chat session — input handling, queue transitions, model
  /// turn HTTP/SSE detail, persist, errors — are intentionally funneled into this one file
  /// so debugging only ever requires opening one log; there is no separate diagnostics file.
  public func makeSessionLogger(sessionId: UUID) -> Logger {
    let level = logLevel.swiftLogLevel
    let dir = URL(fileURLWithPath: logDirectoryPath, isDirectory: true).standardizedFileURL
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let fileURL = dir.appendingPathComponent(
      "scribe-\(sessionId.uuidString).log", isDirectory: false)

    if !FileManager.default.fileExists(atPath: fileURL.path) {
      _ = FileManager.default.createFile(atPath: fileURL.path, contents: nil)
    }
    guard let fileHandle = try? FileHandle(forUpdating: fileURL) else {
      // Last-resort fallback: emit to stderr if we can't open the per-session file.
      // We deliberately do not create a parallel "diagnostics" log here.
      return Logger(label: "scribe.session") { _ in
        ScribeLineLogHandler(
          minimumLevel: level,
          dataWriter: LockedDataWriter { data in
            try? FileHandle.standardError.write(contentsOf: data)
          })
      }
    }
    _ = try? fileHandle.seekToEnd()

    let sink = FileSink(handle: fileHandle)
    let fileWriter = LockedDataWriter { data in sink.write(data) }
    return Logger(label: "scribe.session") { _ in
      ScribeLineLogHandler(minimumLevel: level, dataWriter: fileWriter)
    }
  }
}
