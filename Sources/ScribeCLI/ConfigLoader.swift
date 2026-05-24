import Configuration
import Foundation
import Logging
import ScribeCore
import ScribeLLM
import SystemPackage

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
  public static let reasoningEnabled: ConfigKey = "agent.reasoning"
  public static let loggingLevel: ConfigKey = "logging.level"
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
    var reasoning: Bool?
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

// MARK: - LoadedConfig

/// Loaded configuration bundle returned by `ConfigLoader.load()`.
public struct LoadedConfig: Sendable {
  public var scribeConfig: ScribeConfig
  public var apiBaseURL: String
  public var apiKey: String?
  public var logLevel: ScribeLogLevel
  public var chatSessionsDirectoryPath: String
  public var resolvedConfigurationPath: String
  public var paths: ScribePaths

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

  /// Per-chat logger writing to `sessions/{sessionId}/scribe.log` under the data home.
  public func makeSessionLogger(sessionId: UUID) -> Logger {
    SessionLoggerFactory.makeSessionLogger(
      sessionId: sessionId,
      minimumLevel: logLevel.swiftLogLevel,
      logFile: paths.logFile(sessionId: sessionId)
    )
  }
}

// MARK: - Config loading

public enum ConfigLoader {
  private static let configFileName = "scribe-config.json"

  public static func load() async throws -> LoadedConfig {
    let paths = ScribePaths.resolve()

    // 1. SCRIBE_CONFIG_PATH override — use exactly as given, error if missing.
    if let raw = ProcessInfo.processInfo.environment["SCRIBE_CONFIG_PATH"] {
      let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      if !t.isEmpty {
        return try await loadConfig(at: FilePath(t), paths: paths)
      }
    }

    // 2. Check {dataHome}/scribe-config.json.
    if FileStat.stat(paths.defaultConfigPath).exists {
      return try await loadConfig(at: paths.defaultConfigPath, paths: paths)
    }

    // 3. Check cwd/scribe-config.json.
    let cwd = FilePath.currentDirectory.string
    let cwdCandidate = URL(fileURLWithPath: cwd, isDirectory: true)
      .appendingPathComponent(configFileName).path
    if FileStat.stat(FilePath(cwdCandidate)).exists {
      return try await loadConfig(at: FilePath(cwdCandidate), paths: paths)
    }

    // 4. Not found — write a default config to {dataHome}/, then load it.
    let defaultCandidate = paths.defaultConfigPath
    try writeDefaultConfig(to: defaultCandidate.string)
    if let data = "scribe: no config found — wrote default \(configFileName) to \(defaultCandidate.string)\n"
      .data(using: .utf8)
    {
      try? FileHandle.standardError.write(contentsOf: data)
    }
    return try await loadConfig(at: defaultCandidate, paths: paths)
  }

  private static func loadConfig(
    at path: FilePath,
    paths: ScribePaths
  ) async throws -> LoadedConfig {
    let fileProvider: FileProvider<JSONSnapshot>
    do {
      fileProvider = try await FileProvider<JSONSnapshot>(
        filePath: path)
    } catch {
      throw ScribeError.configuration(
        key: nil,
        reason:
          "Could not load configuration at \(path). Create `\(configFileName)` in `~` or the current directory, or set SCRIBE_CONFIG_PATH to a JSON file path. (\(error))"
      )
    }
    return try await parse(reader: ConfigReader(providers: [fileProvider]), configPath: path, paths: paths)
  }

  private static func parse(
    reader: ConfigReader,
    configPath: FilePath,
    paths: ScribePaths
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

    let reasoningEnabled = try await reader.fetchBool(forKey: ScribeConfigBinding.reasoningEnabled)

    let chatSessionsDirectoryPath = paths.sessionsDirectoryPath

    let resolvedPathString = configPath.string

    let scribeConfig = ScribeConfig(
      agentModel: model,
      contextWindow: contextWindow,
      contextWindowThreshold: contextWindowThreshold,
      serverURL: baseURL,
      apiKey: resolvedAPIKey,
      workingDirectory: ".",
      reasoningEnabled: reasoningEnabled
    )
    return LoadedConfig(
      scribeConfig: scribeConfig,
      apiBaseURL: baseURL,
      apiKey: resolvedAPIKey,
      logLevel: logLevel,
      chatSessionsDirectoryPath: chatSessionsDirectoryPath,
      resolvedConfigurationPath: resolvedPathString,
      paths: paths
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
        contextWindowThreshold: 0.8,
        reasoning: false
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
    try createDirectoryWithIntermediates(FilePath(dir.path))
    try data.write(to: url, options: .atomic)
  }
}
