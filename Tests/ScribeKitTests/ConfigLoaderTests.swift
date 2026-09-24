import Foundation
import ScribeCore
import SystemPackage
import Testing

@testable import ScribeKit

@Suite(.serialized)
struct ConfigLoaderTests {
  @Test func loadsNamedProfileFromExplicitOverride() async throws {
    try await withTemporaryDirectory { root in
      setenv("SCRIBE_HOME", root.path, 1)
      defer { unsetenv("SCRIBE_HOME") }

      let paths = ScribePaths(dataHome: FilePath(root.path))
      try createDirectoryWithIntermediates(paths.dataHome)
      let configJSON = """
        {
          "profiles": [
            {
              "name": "local",
              "api": { "baseUrl": "http://localhost:11434", "apiKey": "" },
              "agent": {
                "model": "gemma4:e2b",
                "contextWindow": 128000,
                "contextWindowThreshold": 0.8,
                "reasoning": false
              },
              "logging": { "level": "trace" }
            },
            {
              "name": "cloud",
              "api": { "baseUrl": "https://api.example.com", "apiKey": "secret" },
              "agent": {
                "model": "big-model",
                "contextWindow": 256000,
                "contextWindowThreshold": 0.9,
                "serviceTier": "priority",
                "serviceTiers": ["default", "priority"]
              },
              "logging": { "level": "trace" }
            }
          ]
        }
        """
      try configJSON.write(
        toFile: paths.profileManifestPath.string, atomically: true, encoding: .utf8)
      let loaded = try await ConfigLoader.load(profileOverride: "cloud")
      #expect(loaded.activeProfileName == "cloud")
      #expect(loaded.scribeConfig.agentModel == "big-model")
      #expect(loaded.scribeConfig.serverURL == "https://api.example.com")
      #expect(loaded.scribeConfig.serviceTier == "priority")
      #expect(loaded.profiles.map(\.name) == ["local", "cloud"])
      #expect(loaded.profiles[1].serviceTiers == ["default", "priority"])
      #expect(loaded.profiles[1].serviceTier == "priority")
      #expect(loaded.resolvedConfigurationPath == paths.profileManifestPath.string)
    }
  }

  @Test func reasoningEffortOptionsLoadWithMediumDefault() async throws {
    try await withTemporaryDirectory { root in
      setenv("SCRIBE_HOME", root.path, 1)
      defer { unsetenv("SCRIBE_HOME") }

      let paths = ScribePaths(dataHome: FilePath(root.path))
      try createDirectoryWithIntermediates(paths.dataHome)
      let configJSON = """
        { "profiles": [
          {
            "name": "codex",
            "api": { "baseUrl": "https://example.com", "apiKey": "" },
            "agent": {
              "model": "gpt-5.6-sol",
              "contextWindow": 128000,
              "contextWindowThreshold": 0.8,
              "reasoningEfforts": ["low", "medium", "high", "xhigh"]
            },
            "logging": { "level": "trace" }
          }
        ] }
        """
      try configJSON.write(
        toFile: paths.profileManifestPath.string, atomically: true, encoding: .utf8)

      let loaded = try await ConfigLoader.load()
      #expect(loaded.profiles[0].reasoningEfforts == ["low", "medium", "high", "xhigh"])
      #expect(loaded.profiles[0].reasoningEffort == "medium")
      #expect(loaded.scribeConfig.reasoningEnabled == true)
      #expect(loaded.scribeConfig.reasoningEffort == "medium")
    }
  }

  @Test func rejectsReasoningEffortNotListedAsSupported() async throws {
    try await withTemporaryDirectory { root in
      setenv("SCRIBE_HOME", root.path, 1)
      defer { unsetenv("SCRIBE_HOME") }

      let paths = ScribePaths(dataHome: FilePath(root.path))
      try createDirectoryWithIntermediates(paths.dataHome)
      let configJSON = """
        { "profiles": [
          {
            "name": "codex",
            "api": { "baseUrl": "https://example.com", "apiKey": "" },
            "agent": {
              "model": "gpt-5.6-sol",
              "contextWindow": 128000,
              "contextWindowThreshold": 0.8,
              "reasoningEfforts": ["low", "high", "high"]
            },
            "logging": { "level": "trace" }
          }
        ] }
        """
      try configJSON.write(
        toFile: paths.profileManifestPath.string, atomically: true, encoding: .utf8)

      await #expect(throws: ScribeError.self) { try await ConfigLoader.load() }
    }
  }

  @Test func rejectsUnsupportedServiceTier() async throws {
    try await withTemporaryDirectory { root in
      setenv("SCRIBE_HOME", root.path, 1)
      defer { unsetenv("SCRIBE_HOME") }

      let paths = ScribePaths(dataHome: FilePath(root.path))
      try createDirectoryWithIntermediates(paths.dataHome)
      let configJSON = """
        { "profiles": [
          {
            "name": "openai",
            "api": { "baseUrl": "https://example.com", "apiKey": "" },
            "agent": {
              "model": "gpt-model",
              "contextWindow": 128000,
              "contextWindowThreshold": 0.8,
              "serviceTier": "fast"
            },
            "logging": { "level": "trace" }
          }
        ] }
        """
      try configJSON.write(
        toFile: paths.profileManifestPath.string, atomically: true, encoding: .utf8)

      await #expect(throws: ScribeError.self) { try await ConfigLoader.load() }
    }
  }

  @Test func profileOverrideTakesPrecedenceOverResumedSessionProfile() async throws {
    try await withTemporaryDirectory { root in
      setenv("SCRIBE_HOME", root.path, 1)
      defer { unsetenv("SCRIBE_HOME") }

      let paths = ScribePaths(dataHome: FilePath(root.path))
      try createDirectoryWithIntermediates(paths.dataHome)
      let configJSON = """
        { "profiles": [
          { "name": "local", "api": { "baseUrl": "http://localhost:11434", "apiKey": "" }, "agent": { "model": "local-model", "contextWindow": 128000, "contextWindowThreshold": 0.8 }, "logging": { "level": "trace" } },
          { "name": "cloud", "api": { "baseUrl": "https://api.example.com", "apiKey": "secret" }, "agent": { "model": "cloud-model", "contextWindow": 128000, "contextWindowThreshold": 0.8 }, "logging": { "level": "trace" } }
        ] }
        """
      try configJSON.write(
        toFile: paths.profileManifestPath.string, atomically: true, encoding: .utf8)

      let sessionID = UUID()
      let directory = paths.sessionDirectory(sessionId: sessionID)
      try await ChatSessionStore.saveMetadata(
        ChatSessionMetadata(
          id: sessionID, createdAt: .distantPast, model: "local-model", profileName: "local",
          cwd: root.path, baseURL: "http://localhost:11434", scribeVersion: nil),
        to: directory)
      try ChatSessionStore.appendMessages([ScribeMessage(role: .system, content: "system")], to: directory)

      let session = try await ScribeSessionBootstrap.open(
        resumeDirectory: directory,
        profileOverride: "cloud",
        workingDirectory: root.path,
        version: "test")

      let configuration = await session.harness.configurationSnapshot()
      #expect(session.profile.name == "cloud")
      #expect(configuration.agentModel == "cloud-model")
    }
  }

  @Test func profileOverrideDoesNotRequireActiveProfileFile() async throws {
    try await withTemporaryDirectory { root in
      setenv("SCRIBE_HOME", root.path, 1)
      defer { unsetenv("SCRIBE_HOME") }

      let paths = ScribePaths(dataHome: FilePath(root.path))
      try createDirectoryWithIntermediates(paths.dataHome)
      let configJSON = """
        {
          "profiles": [
            {
              "name": "only",
              "api": { "baseUrl": "http://127.0.0.1:11434", "apiKey": "" },
              "agent": {
                "model": "m",
                "contextWindow": 1000,
                "contextWindowThreshold": 0.5
              },
              "logging": { "level": "info" }
            }
          ]
        }
        """
      try configJSON.write(
        toFile: paths.profileManifestPath.string, atomically: true, encoding: .utf8)

      let loaded = try await ConfigLoader.load(profileOverride: "only")
      #expect(loaded.activeProfileName == "only")
      #expect(loaded.logLevel == .info)
    }
  }

  @Test func usesFirstProfileAsEphemeralDefault() async throws {
    try await withTemporaryDirectory { root in
      setenv("SCRIBE_HOME", root.path, 1)
      defer { unsetenv("SCRIBE_HOME") }

      let paths = ScribePaths(dataHome: FilePath(root.path))
      try createDirectoryWithIntermediates(paths.dataHome)
      let configJSON = """
        {
          "profiles": [
            {
              "name": "first",
              "api": { "baseUrl": "http://localhost:11434", "apiKey": "" },
              "agent": {
                "model": "a",
                "contextWindow": 128000,
                "contextWindowThreshold": 0.8
              },
              "logging": { "level": "trace" }
            },
            {
              "name": "second",
              "api": { "baseUrl": "http://localhost:11434", "apiKey": "" },
              "agent": {
                "model": "b",
                "contextWindow": 128000,
                "contextWindowThreshold": 0.8
              },
              "logging": { "level": "trace" }
            }
          ]
        }
        """
      try configJSON.write(
        toFile: paths.profileManifestPath.string, atomically: true, encoding: .utf8)

      let loaded = try await ConfigLoader.load()
      #expect(loaded.activeProfileName == "first")
      #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("active-profile.json").path))
    }
  }

  @Test func ignoresLegacyActiveProfileFile() async throws {
    try await withTemporaryDirectory { root in
      setenv("SCRIBE_HOME", root.path, 1)
      defer { unsetenv("SCRIBE_HOME") }

      let paths = ScribePaths(dataHome: FilePath(root.path))
      try createDirectoryWithIntermediates(paths.dataHome)
      let configJSON = """
        {
          "profiles": [
            {
              "name": "first",
              "api": { "baseUrl": "http://localhost:11434", "apiKey": "" },
              "agent": {
                "model": "a",
                "contextWindow": 128000,
                "contextWindowThreshold": 0.8
              },
              "logging": { "level": "trace" }
            },
            {
              "name": "second",
              "api": { "baseUrl": "http://localhost:11434", "apiKey": "" },
              "agent": {
                "model": "b",
                "contextWindow": 128000,
                "contextWindowThreshold": 0.8
              },
              "logging": { "level": "trace" }
            }
          ]
        }
        """
      try configJSON.write(
        toFile: paths.profileManifestPath.string, atomically: true, encoding: .utf8)
      try #"{"activeProfile":"second"}"#.write(
        to: root.appendingPathComponent("active-profile.json"), atomically: true, encoding: .utf8)

      let loaded = try await ConfigLoader.load()
      #expect(loaded.activeProfileName == "first")
      #expect(loaded.scribeConfig.agentModel == "a")
    }
  }

  @Test func rejectsUnknownAPIType() async throws {
    try await withTemporaryDirectory { root in
      setenv("SCRIBE_HOME", root.path, 1)
      defer { unsetenv("SCRIBE_HOME") }

      let paths = ScribePaths(dataHome: FilePath(root.path))
      try createDirectoryWithIntermediates(paths.dataHome)
      let configJSON = """
        {
          "profiles": [
            {
              "name": "legacy",
              "api": { "baseUrl": "https://api.anthropic.com", "apiKey": "secret", "type": "anthropic" },
              "agent": {
                "model": "some-model",
                "contextWindow": 200000,
                "contextWindowThreshold": 0.8
              },
              "logging": { "level": "info" }
            }
          ]
        }
        """
      try configJSON.write(
        toFile: paths.profileManifestPath.string, atomically: true, encoding: .utf8)

      await #expect(throws: ScribeError.self) {
        _ = try await ConfigLoader.load()
      }
    }
  }
}
