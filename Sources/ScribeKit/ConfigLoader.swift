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
  public static let serviceTier = "agent.serviceTier"
  public static let serviceTiers = "agent.serviceTiers"
  public static let temperature = "agent.temperature"
  public static let maxRetries = "agent.maxRetries"
  public static let loggingLevel = "logging.level"
}

public typealias ScribeProfileSummary = ProfileSummary

public struct ProfileSummary: Codable, Sendable, Equatable {

  public var name: String

  public var model: String

  public var baseURL: String

  public var reasoningEfforts: [String]

  public var reasoningEffort: String?

  public var serviceTiers: [String]

  public var serviceTier: String?

  public init(
    name: String,
    model: String,
    baseURL: String,
    reasoningEfforts: [String] = [],
    reasoningEffort: String? = nil,
    serviceTiers: [String] = [],
    serviceTier: String? = nil
  ) {
    self.name = name
    self.model = model
    self.baseURL = baseURL
    self.reasoningEfforts = reasoningEfforts
    self.reasoningEffort = reasoningEffort
    self.serviceTiers = serviceTiers
    self.serviceTier = serviceTier
  }

  private enum CodingKeys: String, CodingKey {
    case name, model, baseURL, reasoningEfforts, reasoningEffort, serviceTiers, serviceTier
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    name = try container.decode(String.self, forKey: .name)
    model = try container.decode(String.self, forKey: .model)
    baseURL = try container.decode(String.self, forKey: .baseURL)
    reasoningEfforts = try container.decodeIfPresent([String].self, forKey: .reasoningEfforts) ?? []
    reasoningEffort = try container.decodeIfPresent(String.self, forKey: .reasoningEffort)
    serviceTiers = try container.decodeIfPresent([String].self, forKey: .serviceTiers) ?? []
    serviceTier = try container.decodeIfPresent(String.self, forKey: .serviceTier)
  }
}

private struct ConfigManifest: Codable {
  struct APISection: Codable {
    var baseUrl: String
    var apiKey: String
    var type: String?
    var opencodeHeader: Bool?
  }
  struct AgentSection: Codable {
    var model: String
    var contextWindow: Int
    var contextWindowThreshold: Double
    var reasoning: Bool?
    var reasoningEffort: String?
    var reasoningEfforts: [String]? = nil
    var serviceTier: String? = nil
    var serviceTiers: [String]? = nil
    var maxTokens: Int?
    var temperature: Double?
    var maxRetries: Int?
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
  public var profiles: [ScribeProfileSummary]
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

  public static func resolvePaths() throws -> ResolvedPaths {
    let paths = ScribePaths.resolve()
    let candidate = environmentConfigurationCandidate(paths: paths)
    return try resolvePaths(paths: paths, configurationFile: candidate)
  }

  public static func resolvePaths(
    paths: ScribePaths,
    configurationFile: FilePath? = nil
  ) throws -> ResolvedPaths {
    if let configurationFile {
      return ResolvedPaths(paths: paths, configPath: configurationFile)
    }
    if FileStat.stat(paths.profileManifestPath).exists {
      return ResolvedPaths(paths: paths, configPath: paths.profileManifestPath)
    }
    try writeDefaultSetup(paths: paths)
    if let data =
      "scribe: no config found — wrote default \(configFileName) to \(paths.dataHomePath)\n"
      .data(using: .utf8)
    {
      try? FileHandle.standardError.write(contentsOf: data)
    }
    return ResolvedPaths(paths: paths, configPath: paths.profileManifestPath)
  }

  public static func load(profileOverride: String? = nil) async throws -> LoadedConfig {
    let resolved = try resolvePaths()
    return try await load(
      paths: resolved.paths, configurationFile: resolved.configPath,
      profileOverride: profileOverride)
  }

  public static func load(
    paths: ScribePaths,
    configurationFile: FilePath? = nil,
    profileOverride: String? = nil
  ) async throws -> LoadedConfig {
    let resolved = try resolvePaths(paths: paths, configurationFile: configurationFile)
    return try await loadConfiguration(
      at: resolved.configPath, paths: resolved.paths, profileOverride: profileOverride)
  }

  private static func environmentConfigurationCandidate(paths: ScribePaths) -> FilePath? {
    if let raw = ProcessInfo.processInfo.environment["SCRIBE_CONFIG_PATH"] {
      let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      if !t.isEmpty {
        return FilePath(t)
      }
    }
    if !FileStat.stat(paths.profileManifestPath).exists {
      let cwd = FilePath.currentDirectory.string
      let cwdCandidate = URL(fileURLWithPath: cwd, isDirectory: true)
        .appendingPathComponent(configFileName).path
      if FileStat.stat(FilePath(cwdCandidate)).exists {
        return FilePath(cwdCandidate)
      }
    }
    return nil
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
        baseURL: entry.api.baseUrl,
        reasoningEfforts: entry.agent.reasoning == false ? [] : (entry.agent.reasoningEfforts ?? []),
        reasoningEffort: entry.agent.reasoning == false
          ? nil
          : (entry.agent.reasoningEffort
            ?? ((entry.agent.reasoningEfforts ?? []).contains("medium")
              ? "medium" : entry.agent.reasoningEfforts?.first)),
        serviceTiers: entry.agent.serviceTiers ?? [],
        serviceTier: entry.agent.serviceTier
          ?? ((entry.agent.serviceTiers ?? []).contains("default")
            ? "default" : entry.agent.serviceTiers?.first)
      )
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
    summaries: [ScribeProfileSummary],
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

    let reasoningEfforts = profile.agent.reasoningEfforts ?? []
    let supportedReasoningEfforts: Set<String> = [
      "none", "minimal", "low", "medium", "high", "xhigh", "max",
    ]
    if let effort = profile.agent.reasoningEffort,
      !supportedReasoningEfforts.contains(effort)
    {
      throw ScribeError.configuration(
        key: ScribeConfigBinding.reasoningEffort,
        reason:
          "`agent.reasoningEffort` must be a supported effort value for profile `\(profileName)`."
      )
    }
    guard reasoningEfforts.allSatisfy({ supportedReasoningEfforts.contains($0) }),
      Set(reasoningEfforts).count == reasoningEfforts.count
    else {
      throw ScribeError.configuration(
        key: "agent.reasoningEfforts",
        reason:
          "`agent.reasoningEfforts` must contain unique supported effort values for profile `\(profileName)`."
      )
    }
    if let selectedEffort = profile.agent.reasoningEffort,
      !reasoningEfforts.isEmpty,
      !reasoningEfforts.contains(selectedEffort)
    {
      throw ScribeError.configuration(
        key: ScribeConfigBinding.reasoningEffort,
        reason:
          "`agent.reasoningEffort` must be included in `agent.reasoningEfforts` for profile `\(profileName)`."
      )
    }
    let configuredEffort =
      profile.agent.reasoningEffort
      ?? (reasoningEfforts.contains("medium") ? "medium" : reasoningEfforts.first)
    let serviceTiers = profile.agent.serviceTiers ?? []
    let supportedServiceTiers: Set<String> = ["auto", "default", "flex", "priority"]
    guard serviceTiers.allSatisfy({ supportedServiceTiers.contains($0) }),
      Set(serviceTiers).count == serviceTiers.count
    else {
      throw ScribeError.configuration(
        key: ScribeConfigBinding.serviceTiers,
        reason:
          "`agent.serviceTiers` must contain unique supported service tiers for profile `\(profileName)`."
      )
    }
    if let selectedTier = profile.agent.serviceTier,
      !supportedServiceTiers.contains(selectedTier)
    {
      throw ScribeError.configuration(
        key: ScribeConfigBinding.serviceTier,
        reason:
          "`agent.serviceTier` must be a supported service tier for profile `\(profileName)`."
      )
    }
    if let selectedTier = profile.agent.serviceTier,
      !serviceTiers.isEmpty,
      !serviceTiers.contains(selectedTier)
    {
      throw ScribeError.configuration(
        key: ScribeConfigBinding.serviceTier,
        reason:
          "`agent.serviceTier` must be included in `agent.serviceTiers` for profile `\(profileName)`."
      )
    }
    let configuredServiceTier =
      profile.agent.serviceTier
      ?? (serviceTiers.contains("default") ? "default" : serviceTiers.first)
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

    if let temperature = profile.agent.temperature, temperature < 0 || temperature > 2 {
      throw ScribeError.configuration(
        key: ScribeConfigBinding.temperature,
        reason:
          "`\(ScribeConfigBinding.temperature)` must be between 0 and 2 for profile `\(profileName)`."
      )
    }

    if let maxRetries = profile.agent.maxRetries, maxRetries < 0 {
      throw ScribeError.configuration(
        key: ScribeConfigBinding.maxRetries,
        reason:
          "`\(ScribeConfigBinding.maxRetries)` must be 0 or greater for profile `\(profileName)`."
      )
    }

    let apiKeyTrimmed = profile.api.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedAPIKey: String? = apiKeyTrimmed.isEmpty ? nil : apiKeyTrimmed
    let apiType = profile.api.type?.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedAPIType: String? = apiType.flatMap { $0.isEmpty ? nil : $0 }

    if let resolvedAPIType {
      guard ["codex", "deepseek", "responses"].contains(resolvedAPIType) else {
        throw ScribeError.configuration(
          key: ScribeConfigBinding.apiType,
          reason:
            "Unknown `\(ScribeConfigBinding.apiType)` value \"\(resolvedAPIType)\" for profile `\(profileName)`; use \"codex\", \"deepseek\", \"responses\", or omit it for OpenAI-compatible providers."
        )
      }
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
      reasoningEnabled: profile.agent.reasoning ?? (!reasoningEfforts.isEmpty ? true : nil),
      reasoningEffort: configuredEffort,
      serviceTier: configuredServiceTier,
      maxTokens: profile.agent.maxTokens,
      sendsOpenCodeHeader: profile.api.opencodeHeader ?? false,
      temperature: profile.agent.temperature,
      maxRetries: profile.agent.maxRetries
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
    summaries: [ScribeProfileSummary],
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
