import Configuration
import Foundation
import Logging

/// Dotted keys in `scribe-config.json` for ``ConfigReader`` (matches nested JSON paths).
/// All application settings are read from that file (see ``AgentConfig/load()``); there are no separate secret lookup paths and keys are not marked `isSecret` (so configuration access logs show values as read).
///
/// Keys include `openai.*`, `agent.*`, `logging.level` (see ``ScribeLogLevel``), and required `logging.storage` (base directory; `logs/` and `sessions/` subdirectories are created under it).
public enum ScribeConfigBinding {
  public static let openAIBaseURL: ConfigKey = "openai.baseUrl"
  public static let openAIAPIKey: ConfigKey = "openai.apiKey"
  public static let agentModel: ConfigKey = "agent.model"
  public static let agentMaxToolRounds: ConfigKey = "agent.maxToolRounds"
  public static let loggingLevel: ConfigKey = "logging.level"
  /// Base directory for all Scribe storage. `logs/` and `sessions/` subdirectories are created under it automatically. Relative paths resolve against the process working directory when the config is loaded. Required.
  public static let loggingStorage: ConfigKey = "logging.storage"
}

public struct AgentConfig: Sendable {
  private static let configFileName = "scribe-config.json"

  public var openAIBaseURL: String
  public var openAIAPIKey: String?
  public var agentModel: String
  public var agentMaxToolRounds: Int
  public var logLevel: ScribeLogLevel
  /// Absolute path of the directory where ``makeSessionLogger(sessionId:)`` appends log files
  /// (`scribe-{uuid}.log`, one per Scribe invocation; no separate diagnostics file).
  public var logDirectoryPath: String
  /// Absolute path of the directory used by ``ChatSessionStore`` for `scribe chat` session files.
  public var chatSessionsDirectoryPath: String
  /// Absolute path of the JSON file ``load()`` read (or attempted), for diagnostics.
  public var resolvedConfigurationPath: String

  public init(
    openAIBaseURL: String,
    openAIAPIKey: String?,
    agentModel: String,
    agentMaxToolRounds: Int,
    logLevel: ScribeLogLevel,
    logDirectoryPath: String,
    chatSessionsDirectoryPath: String,
    resolvedConfigurationPath: String
  ) {
    self.openAIBaseURL = openAIBaseURL
    self.openAIAPIKey = openAIAPIKey
    self.agentModel = agentModel
    self.agentMaxToolRounds = agentMaxToolRounds
    self.logLevel = logLevel
    self.logDirectoryPath = logDirectoryPath
    self.chatSessionsDirectoryPath = chatSessionsDirectoryPath
    self.resolvedConfigurationPath = resolvedConfigurationPath
  }

  public static func load() async throws -> AgentConfig {
    let configPath = resolveScribeConfigPath()

    let fileProvider: FileProvider<JSONSnapshot>
    do {
      fileProvider = try await FileProvider<JSONSnapshot>(filePath: configPath.configurationFilePath)
    } catch {
      throw AgentAPIError(
        description:
          "Could not load configuration at \(configPath). Create `\(configFileName)` in `~`, the current directory (or any ancestor), or set SCRIBE_CONFIG_PATH to a JSON file path. (\(error))"
      )
    }

    let reader = ConfigReader(providers: [fileProvider])

    let baseURL = try await reader.fetchRequiredString(forKey: ScribeConfigBinding.openAIBaseURL)
    guard !baseURL.isEmpty else {
      throw AgentAPIError(
        description:
          "\(ScribeConfigBinding.openAIBaseURL.description) must be a non-empty string in `\(configFileName)`."
      )
    }
    let model = try await reader.fetchRequiredString(forKey: ScribeConfigBinding.agentModel)
    guard !model.isEmpty else {
      throw AgentAPIError(
        description:
          "\(ScribeConfigBinding.agentModel.description) must be a non-empty string in `\(configFileName)`."
      )
    }
    let maxRounds = try await reader.fetchRequiredInt(forKey: ScribeConfigBinding.agentMaxToolRounds)

    let apiKey: String
    do {
      apiKey = try await reader.fetchRequiredString(forKey: ScribeConfigBinding.openAIAPIKey)
    } catch {
      throw AgentAPIError(
        description:
          "`\(ScribeConfigBinding.openAIAPIKey.description)` must be present in `\(configFileName)` (use \"\" when no API key is required, e.g. local Ollama). Underlying error: \(error)"
      )
    }
    let apiKeyTrimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedAPIKey: String? = apiKeyTrimmed.isEmpty ? nil : apiKeyTrimmed

    let levelRaw = try await reader.fetchRequiredString(forKey: ScribeConfigBinding.loggingLevel)
    guard let logLevel = ScribeLogLevel(parsingConfig: levelRaw) else {
      let allowed = ScribeLogLevel.allCases.map(\.rawValue).joined(separator: ", ")
      throw AgentAPIError(
        description:
          "`\(ScribeConfigBinding.loggingLevel.description)` must be one of \(allowed) in `\(configFileName)`."
      )
    }

    let storageRaw = try await reader.fetchRequiredString(forKey: ScribeConfigBinding.loggingStorage)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !storageRaw.isEmpty else {
      throw AgentAPIError(
        description:
          "`\(ScribeConfigBinding.loggingStorage.description)` must be a non-empty path in `\(configFileName)`."
      )
    }
    let storagePath = Self.resolveConfigurableDirectory(configuredRelativeOrAbsolutePath: storageRaw)
    let logDirectoryPath = URL(fileURLWithPath: storagePath, isDirectory: true)
      .appendingPathComponent("logs", isDirectory: true).standardizedFileURL.path
    let chatSessionsDirectoryPath = URL(fileURLWithPath: storagePath, isDirectory: true)
      .appendingPathComponent("sessions", isDirectory: true).standardizedFileURL.path

    let resolvedPathString = PathResolution.fileSystemPath(configPath)
    let config = AgentConfig(
      openAIBaseURL: baseURL,
      openAIAPIKey: resolvedAPIKey,
      agentModel: model,
      agentMaxToolRounds: maxRounds,
      logLevel: logLevel,
      logDirectoryPath: logDirectoryPath,
      chatSessionsDirectoryPath: chatSessionsDirectoryPath,
      resolvedConfigurationPath: resolvedPathString
    )
    // Boot info is intentionally not logged here — `AgentConfig.load()` runs before any chat
    // session id exists, so it has nowhere to write that wouldn't create a parallel
    // diagnostics file. Callers (e.g. `Chat.run`) should mint a session logger via
    // ``makeSessionLogger(sessionId:)`` and emit a `event=chat.session.start` line themselves.
    return config
  }

  private static func resolveConfigurableDirectory(configuredRelativeOrAbsolutePath configured: String?) -> String {
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

  private static func resolveScribeConfigPath() -> ScribeFilePath {
    if let raw = ProcessInfo.processInfo.environment["SCRIBE_CONFIG_PATH"] {
      let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      if !t.isEmpty {
        return ScribeFilePath(t)
      }
    }

    let homeCandidate = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(configFileName, isDirectory: false)
    if FileManager.default.fileExists(atPath: homeCandidate.path) {
      return ScribeFilePath(homeCandidate.path)
    }

    let cwd = FileManager.default.currentDirectoryPath
    var dir = URL(fileURLWithPath: cwd, isDirectory: true).standardizedFileURL

    while true {
      let candidate = dir.appendingPathComponent(configFileName, isDirectory: false)
      if FileManager.default.fileExists(atPath: candidate.path) {
        return ScribeFilePath(candidate.path)
      }
      let parent = dir.deletingLastPathComponent()
      if parent.path == dir.path {
        break
      }
      dir = parent
    }

    return ScribeFilePath(
      URL(fileURLWithPath: cwd, isDirectory: true).appendingPathComponent(configFileName).path)
  }
}
