import Configuration
import Foundation

/// Dotted keys in `scribe-config.json` for ``ConfigReader`` (matches nested JSON paths).
internal enum ScribeConfigBinding {
  static let openAIBaseURL: ConfigKey = "openai.baseUrl"
  static let openAIAPIKey: ConfigKey = "openai.apiKey"
  static let agentModel: ConfigKey = "agent.model"
  static let agentMaxToolRounds: ConfigKey = "agent.maxToolRounds"
}

struct AgentConfig {
  private static let configFileName = "scribe-config.json"

  var openAIBaseURL: String
  var openAIAPIKey: String?
  var agentModel: String
  var agentMaxToolRounds: Int

  static func load() async throws -> AgentConfig {
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

    let apiKey = try await reader.fetchString(forKey: ScribeConfigBinding.openAIAPIKey, isSecret: true)

    return AgentConfig(
      openAIBaseURL: baseURL,
      openAIAPIKey: apiKey,
      agentModel: model,
      agentMaxToolRounds: maxRounds,
    )
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
