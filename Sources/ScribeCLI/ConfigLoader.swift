import Foundation
import Logging
import ScribeCore
import ScribeLLM
import SystemPackage

public enum ScribeConfigBinding {
  public static let apiBaseURL = "api.baseUrl"
  public static let apiKey = "api.apiKey"
  public static let apiType = "api.type"
  public static let agentModel = "agent.model"
  public static let contextWindow = "agent.contextWindow"
  public static let contextWindowThreshold = "agent.contextWindowThreshold"
  public static let reasoningEnabled = "agent.reasoning"
  public static let loggingLevel = "logging.level"
}

public struct ProfileSummary: Sendable, Equatable {
  public var name: String
  public var model: String
  public var baseURL: String

  public init(name: String, model: String, baseURL: String) {
    self.name = name
    self.model = model
    self.baseURL = baseURL
  }
}

private struct ConfigManifest: Codable {
  struct APISection: Codable {
    var baseUrl: String
    var apiKey: String
    var type: String?
  }
  struct AgentSection: Codable {
    var model: String
    var contextWindow: Int
    var contextWindowThreshold: Double
    var reasoning: Bool?
    var maxTokens: Int?
  }
  struct LoggingSection: Codable {
    var level: String
  }
  struct ProfileEntry: Codable {
    var name: String
    var api: APISection
    var agent: AgentSection
    var logging: LoggingSection
  }
  var profiles: [ProfileEntry]
}

/// Credential model for reading stored Moonshot/Kimi API keys.
private struct MoonshotStoredCredential: Codable {
  let apiKey: String
}

public struct LoadedConfig: Sendable {
  public var scribeConfig: ScribeConfig
  public var apiBaseURL: String
  public var apiKey: String?
  public var apiType: String?
  public var logLevel: ScribeLogLevel
  public var chatSessionsDirectoryPath: String
  public var resolvedConfigurationPath: String
  public var activeProfileName: String
  public var profiles: [ProfileSummary]
  public var paths: ScribePaths

  public func makeClient() throws -> Client {
    guard let serverURL = URL(string: apiBaseURL) else {
      throw ScribeError.configuration(
        key: ScribeConfigBinding.apiBaseURL,
        reason:
          "Invalid `\(ScribeConfigBinding.apiBaseURL)` for profile `\(activeProfileName)`. Use host only, no `/v1` (e.g. http://127.0.0.1:11434 for Ollama)."
      )
    }
    return OpenAICompatibleClient.make(serverURL: serverURL, apiKey: apiKey)
  }

  public func makeSessionLogger(sessionId: UUID) -> Logger {
    SessionLoggerFactory.makeSessionLogger(
      sessionId: sessionId,
      minimumLevel: logLevel.swiftLogLevel,
      logFile: paths.logFile(sessionId: sessionId)
    )
  }
}

public enum ConfigLoader {
  private static let configFileName = "scribe.config.json"

  public static func load(profileOverride: String? = nil) async throws -> LoadedConfig {
    let paths = ScribePaths.resolve()
    let configPath = try resolveConfigurationPath(paths: paths)
    return try await loadConfiguration(
      at: configPath, paths: paths, profileOverride: profileOverride)
  }

  private static func resolveConfigurationPath(paths: ScribePaths) throws -> FilePath {
    if let raw = ProcessInfo.processInfo.environment["SCRIBE_CONFIG_PATH"] {
      let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      if !t.isEmpty {
        return FilePath(t)
      }
    }

    if FileStat.stat(paths.profileManifestPath).exists {
      return paths.profileManifestPath
    }

    let cwd = FilePath.currentDirectory.string
    let cwdCandidate = URL(fileURLWithPath: cwd, isDirectory: true)
      .appendingPathComponent(configFileName).path
    if FileStat.stat(FilePath(cwdCandidate)).exists {
      return FilePath(cwdCandidate)
    }

    try writeDefaultSetup(paths: paths)
    if let data =
      "scribe: no config found — wrote default \(configFileName) to \(paths.dataHomePath)\n"
      .data(using: .utf8)
    {
      try? FileHandle.standardError.write(contentsOf: data)
    }
    return paths.profileManifestPath
  }

  private static func loadConfiguration(
    at configPath: FilePath,
    paths: ScribePaths,
    profileOverride: String?
  ) async throws -> LoadedConfig {
    let url = URL(fileURLWithPath: configPath.string)
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch {
      throw ScribeError.configuration(
        key: nil,
        reason:
          "Could not load configuration at \(configPath). Create `\(configFileName)` in `~/.scribe`, or set SCRIBE_CONFIG_PATH to its path. (\(error))"
      )
    }

    let manifest: ConfigManifest
    do {
      manifest = try JSONDecoder().decode(ConfigManifest.self, from: data)
    } catch {
      throw ScribeError.configuration(
        key: "profiles",
        reason:
          "Could not decode `\(configFileName)` — expected a `profiles` array of named entries with `api`, `agent`, and `logging`. (\(error))"
      )
    }

    return try parse(
      manifest: manifest,
      configPath: configPath,
      paths: paths,
      profileOverride: profileOverride)
  }

  private static func parse(
    manifest: ConfigManifest,
    configPath: FilePath,
    paths: ScribePaths,
    profileOverride: String?
  ) throws -> LoadedConfig {
    guard !manifest.profiles.isEmpty else {
      throw ScribeError.configuration(
        key: "profiles",
        reason: "`profiles` must contain at least one entry in `\(configFileName)`."
      )
    }

    var seenNames: Set<String> = []
    for entry in manifest.profiles {
      let trimmedName = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmedName.isEmpty else {
        throw ScribeError.configuration(
          key: "profiles.name",
          reason: "Each profile must have a non-empty `name` in `\(configFileName)`."
        )
      }
      guard seenNames.insert(trimmedName).inserted else {
        throw ScribeError.configuration(
          key: "profiles.name",
          reason: "Duplicate profile name `\(trimmedName)` in `\(configFileName)`."
        )
      }
    }

    let summaries = manifest.profiles.map { entry in
      ProfileSummary(
        name: entry.name.trimmingCharacters(in: .whitespacesAndNewlines),
        model: entry.agent.model,
        baseURL: entry.api.baseUrl)
    }

    let activeName = try resolveActiveProfileName(
      summaries: summaries,
      override: profileOverride)

    guard
      let selected = manifest.profiles.first(where: {
        $0.name.trimmingCharacters(in: .whitespacesAndNewlines) == activeName
      })
    else {
      throw ScribeError.configuration(
        key: "activeProfile",
        reason: "Active profile `\(activeName)` was not found in `\(configFileName)`."
      )
    }

    return try buildLoadedConfig(
      profile: selected,
      profileName: activeName,
      configPath: configPath,
      summaries: summaries,
      paths: paths)
  }

  private static func buildLoadedConfig(
    profile: ConfigManifest.ProfileEntry,
    profileName: String,
    configPath: FilePath,
    summaries: [ProfileSummary],
    paths: ScribePaths
  ) throws -> LoadedConfig {
    let baseURL = profile.api.baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !baseURL.isEmpty else {
      throw ScribeError.configuration(
        key: ScribeConfigBinding.apiBaseURL,
        reason:
          "`\(ScribeConfigBinding.apiBaseURL)` must be a non-empty string for profile `\(profileName)`."
      )
    }

    let model = profile.agent.model.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !model.isEmpty else {
      throw ScribeError.configuration(
        key: ScribeConfigBinding.agentModel,
        reason:
          "`\(ScribeConfigBinding.agentModel)` must be a non-empty string for profile `\(profileName)`."
      )
    }

    let contextWindow = profile.agent.contextWindow
    guard contextWindow > 0 else {
      throw ScribeError.configuration(
        key: ScribeConfigBinding.contextWindow,
        reason:
          "`\(ScribeConfigBinding.contextWindow)` must be a positive integer for profile `\(profileName)`."
      )
    }

    let contextWindowThreshold = profile.agent.contextWindowThreshold
    guard contextWindowThreshold > 0 else {
      throw ScribeError.configuration(
        key: ScribeConfigBinding.contextWindowThreshold,
        reason:
          "`\(ScribeConfigBinding.contextWindowThreshold)` must be a number greater than 0 for profile `\(profileName)`."
      )
    }

    let apiKeyTrimmed = profile.api.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    var resolvedAPIKey: String? = apiKeyTrimmed.isEmpty ? nil : apiKeyTrimmed
    let apiType = profile.api.type?.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedAPIType: String? = apiType.flatMap { $0.isEmpty ? nil : $0 }

    if let resolvedAPIType {
      guard resolvedAPIType == "codex" || resolvedAPIType == "kimi" else {
        throw ScribeError.configuration(
          key: ScribeConfigBinding.apiType,
          reason:
            "Unknown `\(ScribeConfigBinding.apiType)` value \"\(resolvedAPIType)\" for profile `\(profileName)`; use \"codex\", \"kimi\", or omit it for OpenAI-compatible providers."
        )
      }
    }

    if resolvedAPIType == "kimi" {
      if resolvedAPIKey == nil,
        let envKey = ProcessInfo.processInfo.environment["KIMI_API_KEY"]?
          .trimmingCharacters(in: .whitespacesAndNewlines),
        !envKey.isEmpty
      {
        resolvedAPIKey = envKey
      }
      if resolvedAPIKey == nil {
        resolvedAPIKey = try? Self.readMoonshotStoredKey(paths: paths)
      }
      try KimiK3Support.validateMaxCompletionTokens(profile.agent.maxTokens)
      try KimiK3Support.validateEndpoint(apiKey: resolvedAPIKey, serverURL: baseURL)
    }

    let levelRaw = profile.logging.level.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let logLevel = ScribeLogLevel(parsingConfig: levelRaw) else {
      let allowed = ScribeLogLevel.allCases.map(\.rawValue).joined(separator: ", ")
      throw ScribeError.configuration(
        key: ScribeConfigBinding.loggingLevel,
        reason:
          "`\(ScribeConfigBinding.loggingLevel)` must be one of \(allowed) for profile `\(profileName)`."
      )
    }

    let scribeConfig = ScribeConfig(
      agentModel: model,
      contextWindow: contextWindow,
      contextWindowThreshold: contextWindowThreshold,
      serverURL: baseURL,
      apiKey: resolvedAPIKey,
      apiType: resolvedAPIType,
      workingDirectory: ".",
      reasoningEnabled: profile.agent.reasoning,
      maxTokens: profile.agent.maxTokens
    )
    return LoadedConfig(
      scribeConfig: scribeConfig,
      apiBaseURL: baseURL,
      apiKey: resolvedAPIKey,
      apiType: resolvedAPIType,
      logLevel: logLevel,
      chatSessionsDirectoryPath: paths.sessionsDirectoryPath,
      resolvedConfigurationPath: configPath.string,
      activeProfileName: profileName,
      profiles: summaries,
      paths: paths
    )
  }

  private static func resolveActiveProfileName(
    summaries: [ProfileSummary],
    override: String?
  ) throws -> String {
    if let override {
      let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else {
        throw ScribeError.configuration(
          key: "activeProfile",
          reason: "`--profile` must be a non-empty profile name."
        )
      }
      guard summaries.contains(where: { $0.name == trimmed }) else {
        let available = summaries.map(\.name).joined(separator: ", ")
        throw ScribeError.configuration(
          key: "activeProfile",
          reason: "Unknown profile `\(trimmed)`. Available profiles: \(available)."
        )
      }
      return trimmed
    }

    return summaries[0].name
  }

  private static func writeDefaultSetup(paths: ScribePaths) throws {
    let template = ConfigManifest(
      profiles: [
        ConfigManifest.ProfileEntry(
          name: "local",
          api: ConfigManifest.APISection(
            baseUrl: "http://localhost:11434",
            apiKey: ""
          ),
          agent: ConfigManifest.AgentSection(
            model: "gemma4:e2b",
            contextWindow: 128000,
            contextWindowThreshold: 0.8,
            reasoning: false
          ),
          logging: ConfigManifest.LoggingSection(level: "trace")
        )
      ]
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(template)
    let url = URL(fileURLWithPath: paths.profileManifestPath.string)
    let dir = url.deletingLastPathComponent()
    try createDirectoryWithIntermediates(FilePath(dir.path))
    try data.write(to: url, options: .atomic)
  }

  private static func readMoonshotStoredKey(paths: ScribePaths) throws -> String? {
    let url = URL(fileURLWithPath: paths.dataHomePath)
      .appendingPathComponent("moonshot-api-key.json")
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let data = try Data(contentsOf: url)
    let decoded = try JSONDecoder().decode(MoonshotStoredCredential.self, from: data)
    let trimmed = decoded.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
