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
  public static let reasoningEffort = "agent.reasoningEffort"
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
    var reasoningEffort: String?
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

public struct CodexProfileUpsert: Sendable, Equatable {
  public var profileName: String
  public var created: Bool

  public init(profileName: String, created: Bool) {
    self.profileName = profileName
    self.created = created
  }
}

/// Lightweight result that only resolves paths and config file location.
/// Does NOT parse the manifest or validate any profile — safe for use by
/// `--login`, `--logout`, and `--list-sessions` even when a profile is broken.
public struct ResolvedPaths: Sendable {
  public var paths: ScribePaths
  public var configPath: FilePath

  public var dataHomePath: String { paths.dataHomePath }
  public var resolvedConfigurationPath: String { configPath.string }
}

public enum ConfigLoader {
  private static let configFileName = "scribe.config.json"

  public static let codexProfileName = "codex"
  public static let codexProfileBaseURL = "https://chatgpt.com/backend-api"
  public static let codexProfileModel = "gpt-5.6-sol"

  /// Resolve Scribe data home and the config file path (creating a default
  /// config when none exists).  No profile is selected or validated.
  public static func resolvePaths() throws -> ResolvedPaths {
    let paths = ScribePaths.resolve()
    let configPath = try resolveConfigurationPath(paths: paths)
    return ResolvedPaths(paths: paths, configPath: configPath)
  }

  /// Fully load and validate the active profile (or the named override).
  /// Throws when the config is missing, malformed, or the active profile fails
  /// validation — use `resolvePaths()` for operations that only need paths.
  public static func load(profileOverride: String? = nil) async throws -> LoadedConfig {
    let resolved = try resolvePaths()
    return try await loadConfiguration(
      at: resolved.configPath, paths: resolved.paths, profileOverride: profileOverride)
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
      reasoningEffort: profile.agent.reasoningEffort,
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

  /// Adds the ChatGPT/Codex profile to the config file, or repairs the `api`
  /// section of an existing profile with the same name. Called after a
  /// successful `scribe --login` so the login leaves behind a runnable profile.
  @discardableResult
  public static func upsertCodexProfile(at configPath: FilePath) throws -> CodexProfileUpsert {
    let url = URL(fileURLWithPath: configPath.string)
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch {
      throw ScribeError.configuration(
        key: nil,
        reason:
          "Could not read `\(configPath.string)` to add the `\(codexProfileName)` profile. (\(error))")
    }

    let manifest: ConfigManifest
    do {
      manifest = try JSONDecoder().decode(ConfigManifest.self, from: data)
    } catch {
      throw ScribeError.configuration(
        key: "profiles",
        reason:
          "Could not decode `\(configPath.string)` to add the `\(codexProfileName)` profile. (\(error))")
    }

    var profiles = manifest.profiles
    var created = false
    if let index = profiles.firstIndex(where: {
      $0.name.trimmingCharacters(in: .whitespacesAndNewlines) == codexProfileName
    }) {
      // Keep the user's model/logging/apiKey; only repoint the API section.
      profiles[index].api.type = "codex"
      profiles[index].api.baseUrl = codexProfileBaseURL
    } else {
      profiles.append(
        ConfigManifest.ProfileEntry(
          name: codexProfileName,
          api: ConfigManifest.APISection(
            baseUrl: codexProfileBaseURL,
            apiKey: "",
            type: "codex"
          ),
          agent: ConfigManifest.AgentSection(
            model: codexProfileModel,
            contextWindow: 400000,
            contextWindowThreshold: 0.8,
            reasoning: true
          ),
          logging: ConfigManifest.LoggingSection(level: "trace")
        ))
      created = true
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let encoded = try encoder.encode(ConfigManifest(profiles: profiles))
    try encoded.write(to: url, options: .atomic)

    return CodexProfileUpsert(profileName: codexProfileName, created: created)
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
}
