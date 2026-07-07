import Foundation
import ScribeCore
import SystemPackage
import Testing

@testable import ScribeCLI

@Suite(.serialized)
struct ConfigLoaderTests {
  @Test func loadsNamedProfileFromManifestAndActiveProfileFile() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

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
              "contextWindowThreshold": 0.9
            },
            "logging": { "level": "trace" }
          }
        ]
      }
      """
    try configJSON.write(
      toFile: paths.profileManifestPath.string, atomically: true, encoding: .utf8)
    try ActiveProfileStore.write("cloud", paths: paths)

    let loaded = try await ConfigLoader.load()
    #expect(loaded.activeProfileName == "cloud")
    #expect(loaded.scribeConfig.agentModel == "big-model")
    #expect(loaded.scribeConfig.serverURL == "https://api.example.com")
    #expect(loaded.profiles.map(\.name) == ["local", "cloud"])
    #expect(loaded.resolvedConfigurationPath == paths.profileManifestPath.string)
  }

  @Test func profileOverrideDoesNotRequireActiveProfileFile() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

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

  @Test func writesActiveProfileFileWhenMissing() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

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
    #expect(try ActiveProfileStore.read(from: paths) == "first")
  }
}
