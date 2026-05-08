import Configuration
import Foundation
import Logging
import ScribeCore
import ScribeLLM
import Synchronization

// MARK: - Config key bindings

/// Dotted keys in `scribe-config.json` for `ConfigReader` (matches nested JSON paths).
/// All application settings are read from that file; there are no separate secret lookup
/// paths and keys are not marked `isSecret`.
public enum ScribeConfigBinding {
  public static let apiBaseURL: ConfigKey = "api.baseUrl"
  public static let apiKey: ConfigKey = "api.apiKey"
  public static let agentModel: ConfigKey = "agent.model"
  public static let contextWindow: ConfigKey = "agent.contextWindow"
  public static let contextWindowThreshold: ConfigKey = "agent.contextWindowThreshold"
  public static let loggingLevel: ConfigKey = "logging.level"
}

// MARK: - Log level

/// Severity-ordered levels for `logging.level` in `scribe-config.json`.
///
/// A configured minimum level emits that level and all *more severe* levels (e.g. `info`
/// also allows `notice`, `warning`, and `error`).
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

  /// Corresponding `Logger.Level` for swift-log (same raw strings).
  public var swiftLogLevel: Logger.Level {
    Logger.Level(rawValue: rawValue) ?? .info
  }

  init?(parsingConfig raw: String) {
    let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !s.isEmpty else { return nil }
    self.init(rawValue: s)
  }
}

// MARK: - Logging infrastructure

final class LockedDataWriter: Sendable {
  private let mutex = Mutex(())
  private let emit: @Sendable (Data) -> Void

  init(_ emit: @escaping @Sendable (Data) -> Void) {
    self.emit = emit
  }

  func write(_ data: Data) {
    mutex.withLock { _ in emit(data) }
  }
}

final class FileSink: Sendable {
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

/// Lock-protected `ISO8601DateFormatter` so a single shared instance can be reused from many
/// tasks under strict concurrency.
private let scribeLogTimestampFormatter: Mutex<ISO8601DateFormatter> = {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return Mutex(formatter)
}()

/// One log line per call, formatted as
/// `<iso8601-ms> [<level>] <message>` so each line is timestamped and easy to grep.
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
    if let metadata = event.metadata, !metadata.isEmpty {
      let pairs = metadata.map { key, value in
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

// MARK: - Codable mirror for writing a default config file

/// Mirror of `scribe-config.json` used only when a default must be written to disk.
private struct ConfigTemplate: Codable {
  struct APISection: Codable {
    var baseUrl: String
    var apiKey: String
  }
  struct AgentSection: Codable {
    var model: String
    var contextWindow: Int
    var contextWindowThreshold: Double
  }
  struct LoggingSection: Codable {
    var level: String
  }
  var api: APISection
  var agent: AgentSection
  var logging: LoggingSection

  enum CodingKeys: String, CodingKey {
    case api
    case agent
    case logging
  }
}

// MARK: - ConfigLoader

/// Loaded configuration bundle returned by `ConfigLoader.load()`.
public struct LoadedConfig: Sendable {
  public var scribeConfig: ScribeConfig
  public var apiBaseURL: String
  public var apiKey: String?
  public var logLevel: ScribeLogLevel
  public var logDirectoryPath: String
  public var chatSessionsDirectoryPath: String
  public var resolvedConfigurationPath: String

  public func makeClient() throws -> Client {
    guard let serverURL = URL(string: apiBaseURL) else {
      throw ScribeError.configuration(
        key: ScribeConfigBinding.apiBaseURL.description,
        reason:
          "Invalid \(ScribeConfigBinding.apiBaseURL.description) in `scribe-config.json`. Use host only, no `/v1` (e.g. http://127.0.0.1:11434 for Ollama)."
      )
    }
    return OpenAICompatibleClient.make(serverURL: serverURL, apiKey: apiKey)
  }

  /// Returns a logger appending all events for one Scribe invocation to
  /// `logDirectoryPath`/`scribe-{sessionId}.log`. Pass the chat session id when one exists
  /// (so the log file shares a UUID stem with the matching `{uuid}.json` transcript archive),
  /// or a freshly-minted UUID for ephemeral / non-chat invocations.
  public func makeSessionLogger(sessionId: UUID) -> Logger {
    let level = logLevel.swiftLogLevel
    let dir = URL(fileURLWithPath: logDirectoryPath, isDirectory: true).standardizedFileURL
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let fileURL = dir.appendingPathComponent(
      "scribe-\(sessionId.uuidString).log", isDirectory: false)

    if !FileManager.default.fileExists(atPath: fileURL.path) {
      _ = FileManager.default.createFile(atPath: fileURL.path, contents: nil)
    }
    if let fileHandle = try? FileHandle(forUpdating: fileURL) {
      _ = try? fileHandle.seekToEnd()
      let sink = FileSink(handle: fileHandle)
      let fileWriter = LockedDataWriter { data in sink.write(data) }
      return Logger(label: "scribe.session") { _ in
        ScribeLineLogHandler(minimumLevel: level, dataWriter: fileWriter)
      }
    }
    // Last-resort fallback: emit to stderr if we can't open the per-session file.
    return Logger(label: "scribe.session") { _ in
      ScribeLineLogHandler(
        minimumLevel: level,
        dataWriter: LockedDataWriter { data in
          try? FileHandle.standardError.write(contentsOf: data)
        })
    }
  }
}

// MARK: - Config loading

public enum ConfigLoader {
  private static let configFileName = "scribe-config.json"

  public static func load() async throws -> LoadedConfig {
    // 1. SCRIBE_CONFIG_PATH override — use exactly as given, error if missing.
    if let raw = ProcessInfo.processInfo.environment["SCRIBE_CONFIG_PATH"] {
      let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      if !t.isEmpty {
        return try await loadConfig(at: ScribeFilePath(t))
      }
    }

    // 2. Check ~/.scribe/scribe-config.json.
    let homeScribeCandidate = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".scribe/\(configFileName)", isDirectory: false)
    if FileManager.default.fileExists(atPath: homeScribeCandidate.path) {
      return try await loadConfig(at: ScribeFilePath(homeScribeCandidate.path))
    }

    // 3. Check cwd/scribe-config.json.
    let cwd = FileManager.default.currentDirectoryPath
    let cwdCandidate = URL(fileURLWithPath: cwd, isDirectory: true)
      .appendingPathComponent(configFileName).path
    if FileManager.default.fileExists(atPath: cwdCandidate) {
      return try await loadConfig(at: ScribeFilePath(cwdCandidate))
    }

    // 4. Not found — write a default config to ~/.scribe/, then load it.
    let defaultCandidate = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".scribe/\(configFileName)", isDirectory: false).path
    try writeDefaultConfig(to: defaultCandidate)
    if let data = "scribe: no config found — wrote default \(configFileName) to \(defaultCandidate)\n"
      .data(using: .utf8)
    {
      try? FileHandle.standardError.write(contentsOf: data)
    }
    return try await loadConfig(at: ScribeFilePath(defaultCandidate))
  }

  private static func loadConfig(at path: ScribeFilePath) async throws -> LoadedConfig {
    let fileProvider: FileProvider<JSONSnapshot>
    do {
      fileProvider = try await FileProvider<JSONSnapshot>(
        filePath: path.configurationFilePath)
    } catch {
      throw ScribeError.configuration(
        key: nil,
        reason:
          "Could not load configuration at \(path). Create `\(configFileName)` in `~` or the current directory, or set SCRIBE_CONFIG_PATH to a JSON file path. (\(error))"
      )
    }
    return try await parse(reader: ConfigReader(providers: [fileProvider]), configPath: path)
  }

  private static func parse(
    reader: ConfigReader,
    configPath: ScribeFilePath
  ) async throws -> LoadedConfig {
    let baseURL = try await reader.fetchRequiredString(forKey: ScribeConfigBinding.apiBaseURL)
    guard !baseURL.isEmpty else {
      throw ScribeError.configuration(
        key: ScribeConfigBinding.apiBaseURL.description,
        reason:
          "\(ScribeConfigBinding.apiBaseURL.description) must be a non-empty string in `\(configFileName)`."
      )
    }
    let model = try await reader.fetchRequiredString(forKey: ScribeConfigBinding.agentModel)
    guard !model.isEmpty else {
      throw ScribeError.configuration(
        key: ScribeConfigBinding.agentModel.description,
        reason:
          "\(ScribeConfigBinding.agentModel.description) must be a non-empty string in `\(configFileName)`."
      )
    }

    let contextWindow = try await reader.fetchRequiredInt(
      forKey: ScribeConfigBinding.contextWindow)
    guard contextWindow > 0 else {
      throw ScribeError.configuration(
        key: ScribeConfigBinding.contextWindow.description,
        reason:
          "`\(ScribeConfigBinding.contextWindow.description)` must be a positive integer in `\(configFileName)`."
      )
    }

    let contextWindowThreshold = try await reader.fetchRequiredDouble(
      forKey: ScribeConfigBinding.contextWindowThreshold)
    guard contextWindowThreshold > 0 else {
      throw ScribeError.configuration(
        key: ScribeConfigBinding.contextWindowThreshold.description,
        reason:
          "`\(ScribeConfigBinding.contextWindowThreshold.description)` must be a number greater than 0 in `\(configFileName)`."
      )
    }

    let apiKey: String
    do {
      apiKey = try await reader.fetchRequiredString(
        forKey: ScribeConfigBinding.apiKey)
    } catch {
      throw ScribeError.configuration(
        key: ScribeConfigBinding.apiKey.description,
        reason:
          "`\(ScribeConfigBinding.apiKey.description)` must be present in `\(configFileName)` (use \"\" when no API key is required, e.g. local Ollama). Underlying error: \(error)"
      )
    }
    let apiKeyTrimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedAPIKey: String? = apiKeyTrimmed.isEmpty ? nil : apiKeyTrimmed

    let levelRaw = try await reader.fetchRequiredString(
      forKey: ScribeConfigBinding.loggingLevel)
    guard let logLevel = ScribeLogLevel(parsingConfig: levelRaw) else {
      let allowed = ScribeLogLevel.allCases.map(\.rawValue).joined(separator: ", ")
      throw ScribeError.configuration(
        key: ScribeConfigBinding.loggingLevel.description,
        reason:
          "`\(ScribeConfigBinding.loggingLevel.description)` must be one of \(allowed) in `\(configFileName)`."
      )
    }

    let scribeHome = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".scribe", isDirectory: true)
    let logDirectoryPath = scribeHome
      .appendingPathComponent("logs", isDirectory: true).standardizedFileURL.path
    let chatSessionsDirectoryPath = scribeHome
      .appendingPathComponent("sessions", isDirectory: true).standardizedFileURL.path

    let resolvedPathString = PathResolution.fileSystemPath(configPath)

    let scribeConfig = ScribeConfig(
      agentModel: model,
      contextWindow: contextWindow,
      contextWindowThreshold: contextWindowThreshold,
      serverURL: baseURL,
      apiKey: resolvedAPIKey
    )
    return LoadedConfig(
      scribeConfig: scribeConfig,
      apiBaseURL: baseURL,
      apiKey: resolvedAPIKey,
      logLevel: logLevel,
      logDirectoryPath: logDirectoryPath,
      chatSessionsDirectoryPath: chatSessionsDirectoryPath,
      resolvedConfigurationPath: resolvedPathString
    )
  }

  // MARK: - Write default config

  private static func writeDefaultConfig(to path: String) throws {
    let template = ConfigTemplate(
      api: ConfigTemplate.APISection(
        baseUrl: "http://localhost:11434",
        apiKey: ""
      ),
      agent: ConfigTemplate.AgentSection(
        model: "gemma4:e2b",
        contextWindow: 128000,
        contextWindowThreshold: 0.8
      ),
      logging: ConfigTemplate.LoggingSection(
        level: "trace"
      )
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(template)
    let url = URL(fileURLWithPath: path)
    let dir = url.deletingLastPathComponent()
    if !FileManager.default.fileExists(atPath: dir.path) {
      try FileManager.default.createDirectory(
        at: dir, withIntermediateDirectories: true)
    }
    try data.write(to: url, options: .atomic)
  }
}
