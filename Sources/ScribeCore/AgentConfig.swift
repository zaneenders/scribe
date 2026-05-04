import Configuration
import Foundation
import Logging
import ScribeLLM

/// Dotted keys in `scribe-config.json` for ``ConfigReader`` (matches nested JSON paths).
/// All application settings are read from that file (see ``AgentConfig/load()``); there are no
/// separate secret lookup paths and keys are not marked `isSecret`.
public enum ScribeConfigBinding {
  public static let openAIBaseURL: ConfigKey = "openai.baseUrl"
  public static let openAIAPIKey: ConfigKey = "openai.apiKey"
  public static let agentModel: ConfigKey = "agent.model"
  public static let agentMaxToolRounds: ConfigKey = "agent.maxToolRounds"
  public static let contextWindow: ConfigKey = "agent.contextWindow"
  public static let contextWindowThreshold: ConfigKey = "agent.contextWindowThreshold"
  public static let loggingLevel: ConfigKey = "logging.level"
  /// Base directory for all Scribe storage. `logs/` and `sessions/` subdirectories are
  /// created under it automatically. Relative paths resolve against the process working
  /// directory when the config is loaded. Required.
  public static let loggingStorage: ConfigKey = "logging.storage"
}

// MARK: - Codable mirror for writing a default config file

/// Mirror of `scribe-config.json` used only when a default must be written to disk.
private struct ConfigTemplate: Codable {
  struct LLMSection: Codable {
    var baseUrl: String
    var apiKey: String
  }
  struct AgentSection: Codable {
    var model: String
    var maxToolRounds: Int
    var contextWindow: Int
    var contextWindowThreshold: Double
  }
  struct LoggingSection: Codable {
    var level: String
    var storage: String
  }
  var llm: LLMSection
  var agent: AgentSection
  var logging: LoggingSection

  enum CodingKeys: String, CodingKey {
    case llm = "openai"
    case agent
    case logging
  }
}

// MARK: - AgentConfig

public struct AgentConfig: Sendable {
  private static let configFileName = "scribe-config.json"

  public var openAIBaseURL: String
  public var openAIAPIKey: String?
  public var agentModel: String
  public var agentMaxToolRounds: Int
  public var contextWindow: Int
  public var contextWindowThreshold: Double
  public var logLevel: ScribeLogLevel
  /// Absolute path of the directory where `makeSessionLogger(sessionId:)` appends log files.
  public var logDirectoryPath: String
  /// Absolute path of the directory used by `ChatSessionStore` for `scribe chat` session files.
  public var chatSessionsDirectoryPath: String
  /// Absolute path of the JSON file `load()` read, for diagnostics.
  public var resolvedConfigurationPath: String

  public init(
    openAIBaseURL: String,
    openAIAPIKey: String?,
    agentModel: String,
    agentMaxToolRounds: Int,
    contextWindow: Int,
    contextWindowThreshold: Double,
    logLevel: ScribeLogLevel,
    logDirectoryPath: String,
    chatSessionsDirectoryPath: String,
    resolvedConfigurationPath: String
  ) {
    self.openAIBaseURL = openAIBaseURL
    self.openAIAPIKey = openAIAPIKey
    self.agentModel = agentModel
    self.agentMaxToolRounds = agentMaxToolRounds
    self.contextWindow = contextWindow
    self.contextWindowThreshold = contextWindowThreshold
    self.logLevel = logLevel
    self.logDirectoryPath = logDirectoryPath
    self.chatSessionsDirectoryPath = chatSessionsDirectoryPath
    self.resolvedConfigurationPath = resolvedConfigurationPath
  }

  /// Builds the OpenAI-compatible HTTP client from this configuration.
  public func makeClient() throws -> Client {
    guard let serverURL = URL(string: openAIBaseURL) else {
      throw ScribeError.configuration(
        key: ScribeConfigBinding.openAIBaseURL.description,
        reason:
          "Invalid \(ScribeConfigBinding.openAIBaseURL.description) in `scribe-config.json`. Use host only, no `/v1` (e.g. http://127.0.0.1:11434 for Ollama)."
      )
    }
    return OpenAICompatibleClient.make(serverURL: serverURL, bearerToken: openAIAPIKey)
  }

  public static func load() async throws -> AgentConfig {
    // 1. SCRIBE_CONFIG_PATH override — use exactly as given, error if missing.
    if let raw = ProcessInfo.processInfo.environment["SCRIBE_CONFIG_PATH"] {
      let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      if !t.isEmpty {
        return try await loadConfig(at: ScribeFilePath(t))
      }
    }

    // 2. Check ~/.config/scribe/scribe-config.json.
    let homeCandidate = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".config/scribe/\(configFileName)", isDirectory: false)
    if FileManager.default.fileExists(atPath: homeCandidate.path) {
      return try await loadConfig(at: ScribeFilePath(homeCandidate.path))
    }

    // 3. Check cwd/scribe-config.json.
    let cwd = FileManager.default.currentDirectoryPath
    let cwdCandidate = URL(fileURLWithPath: cwd, isDirectory: true)
      .appendingPathComponent(configFileName).path
    if FileManager.default.fileExists(atPath: cwdCandidate) {
      return try await loadConfig(at: ScribeFilePath(cwdCandidate))
    }

    // 4. Not found — write a default config to cwd, then load it.
    try writeDefaultConfig(to: cwdCandidate)
    if let data = "scribe: no config found — wrote default \(configFileName) to \(cwdCandidate)\n"
      .data(using: .utf8)
    {
      try? FileHandle.standardError.write(contentsOf: data)
    }
    return try await loadConfig(at: ScribeFilePath(cwdCandidate))
  }

  private static func loadConfig(at path: ScribeFilePath) async throws -> AgentConfig {
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

  /// Shared between `load()` and tests that already have an in-memory provider.
  static func parse(
    reader: ConfigReader,
    configPath: ScribeFilePath
  ) async throws -> AgentConfig {
    let baseURL = try await reader.fetchRequiredString(forKey: ScribeConfigBinding.openAIBaseURL)
    guard !baseURL.isEmpty else {
      throw ScribeError.configuration(
        key: ScribeConfigBinding.openAIBaseURL.description,
        reason:
          "\(ScribeConfigBinding.openAIBaseURL.description) must be a non-empty string in `\(configFileName)`."
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
    let maxRounds = try await reader.fetchRequiredInt(
      forKey: ScribeConfigBinding.agentMaxToolRounds)

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
        forKey: ScribeConfigBinding.openAIAPIKey)
    } catch {
      throw ScribeError.configuration(
        key: ScribeConfigBinding.openAIAPIKey.description,
        reason:
          "`\(ScribeConfigBinding.openAIAPIKey.description)` must be present in `\(configFileName)` (use \"\" when no API key is required, e.g. local Ollama). Underlying error: \(error)"
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

    let storageRaw = try await reader.fetchRequiredString(
      forKey: ScribeConfigBinding.loggingStorage
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !storageRaw.isEmpty else {
      throw ScribeError.configuration(
        key: ScribeConfigBinding.loggingStorage.description,
        reason:
          "`\(ScribeConfigBinding.loggingStorage.description)` must be a non-empty path in `\(configFileName)`."
      )
    }
    let storagePath = resolveConfigurableDirectory(
      configuredRelativeOrAbsolutePath: storageRaw)
    let logDirectoryPath = URL(fileURLWithPath: storagePath, isDirectory: true)
      .appendingPathComponent("logs", isDirectory: true).standardizedFileURL.path
    let chatSessionsDirectoryPath = URL(fileURLWithPath: storagePath, isDirectory: true)
      .appendingPathComponent("sessions", isDirectory: true).standardizedFileURL.path

    let resolvedPathString = PathResolution.fileSystemPath(configPath)
    return AgentConfig(
      openAIBaseURL: baseURL,
      openAIAPIKey: resolvedAPIKey,
      agentModel: model,
      agentMaxToolRounds: maxRounds,
      contextWindow: contextWindow,
      contextWindowThreshold: contextWindowThreshold,
      logLevel: logLevel,
      logDirectoryPath: logDirectoryPath,
      chatSessionsDirectoryPath: chatSessionsDirectoryPath,
      resolvedConfigurationPath: resolvedPathString
    )
  }

  // MARK: - Write default config

  private static func writeDefaultConfig(to path: String) throws {
    let template = ConfigTemplate(
      llm: ConfigTemplate.LLMSection(
        baseUrl: "http://localhost:11434",
        apiKey: ""
      ),
      agent: ConfigTemplate.AgentSection(
        model: "gemma4:e2b",
        maxToolRounds: 256,
        contextWindow: 128000,
        contextWindowThreshold: 0.8
      ),
      logging: ConfigTemplate.LoggingSection(
        level: "trace",
        storage: "~/.local/share/scribe"
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

  // MARK: - Path helpers

  private static func resolveConfigurableDirectory(
    configuredRelativeOrAbsolutePath configured: String?
  ) -> String {
    let trimmed = configured?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let cwd = FileManager.default.currentDirectoryPath
    if trimmed.isEmpty {
      return cwd
    }
    let expanded = NSString(string: trimmed).expandingTildeInPath
    if expanded.hasPrefix("/") {
      return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL.path
    }
    return URL(fileURLWithPath: cwd, isDirectory: true)
      .appendingPathComponent(expanded, isDirectory: true)
      .standardizedFileURL.path
  }
}
