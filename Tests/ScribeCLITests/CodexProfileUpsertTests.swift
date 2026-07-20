import Foundation
import ScribeCore
import SystemPackage
import Testing

@testable import ScribeCLI

@Suite(.serialized)
struct CodexProfileUpsertTests {

  private func writeConfig(_ body: String) throws -> (root: URL, path: FilePath) {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("scribe.config.json")
    try body.write(to: file, atomically: true, encoding: .utf8)
    return (root, FilePath(file.path))
  }

  private func readManifest(_ path: FilePath) throws -> [String: Any] {
    let data = try Data(contentsOf: URL(fileURLWithPath: path.string))
    let object = try JSONSerialization.jsonObject(with: data)
    guard let manifest = object as? [String: Any] else {
      throw ScribeError.configuration(key: "profiles", reason: "Manifest is not a JSON object")
    }
    return manifest
  }

  @Test func upsertCreatesCodexProfile() throws {
    let (root, path) = try writeConfig(
      """
      {
        "profiles": [
          {
            "name": "local",
            "api": { "baseUrl": "http://localhost:11434", "apiKey": "" },
            "agent": {
              "model": "gemma4:e2b",
              "contextWindow": 128000,
              "contextWindowThreshold": 0.8
            },
            "logging": { "level": "trace" }
          }
        ]
      }
      """)
    defer { try? FileManager.default.removeItem(at: root) }

    let upsert = try ConfigLoader.upsertCodexProfile(at: path)
    #expect(upsert.created)
    #expect(upsert.profileName == "codex")

    let manifest = try readManifest(path)
    let profiles = try #require(manifest["profiles"] as? [[String: Any]])
    #expect(profiles.map { $0["name"] as? String } == ["local", "codex"])

    let codex = profiles[1]
    let api = try #require(codex["api"] as? [String: Any])
    #expect(api["type"] as? String == "codex")
    #expect(api["baseUrl"] as? String == ConfigLoader.codexProfileBaseURL)
    #expect(api["apiKey"] as? String == "")
    let agent = try #require(codex["agent"] as? [String: Any])
    #expect(agent["model"] as? String == ConfigLoader.codexProfileModel)
  }

  @Test func upsertRepairsExistingCodexProfile() throws {
    let (root, path) = try writeConfig(
      """
      {
        "profiles": [
          {
            "name": "codex",
            "api": { "baseUrl": "https://example.com", "apiKey": "keep-me" },
            "agent": {
              "model": "custom-model",
              "contextWindow": 111,
              "contextWindowThreshold": 0.5
            },
            "logging": { "level": "info" }
          }
        ]
      }
      """)
    defer { try? FileManager.default.removeItem(at: root) }

    let upsert = try ConfigLoader.upsertCodexProfile(at: path)
    #expect(!upsert.created)

    let manifest = try readManifest(path)
    let profiles = try #require(manifest["profiles"] as? [[String: Any]])
    #expect(profiles.count == 1)

    let profile = profiles[0]
    #expect(profile["name"] as? String == "codex")

    let api = try #require(profile["api"] as? [String: Any])
    #expect(api["type"] as? String == "codex")
    #expect(api["baseUrl"] as? String == ConfigLoader.codexProfileBaseURL)
    // Existing apiKey, model, and logging are preserved.
    #expect(api["apiKey"] as? String == "keep-me")
    let agent = try #require(profile["agent"] as? [String: Any])
    #expect(agent["model"] as? String == "custom-model")
    let logging = try #require(profile["logging"] as? [String: Any])
    #expect(logging["level"] as? String == "info")
  }

  @Test func upsertLeavesOtherProfilesUntouched() throws {
    let (root, path) = try writeConfig(
      """
      {
        "profiles": [
          {
            "name": "local",
            "api": { "baseUrl": "http://localhost:11434", "apiKey": "" },
            "agent": {
              "model": "gemma4:e2b",
              "contextWindow": 128000,
              "contextWindowThreshold": 0.8
            },
            "logging": { "level": "trace" }
          }
        ]
      }
      """)
    defer { try? FileManager.default.removeItem(at: root) }

    _ = try ConfigLoader.upsertCodexProfile(at: path)

    let manifest = try readManifest(path)
    let profiles = try #require(manifest["profiles"] as? [[String: Any]])
    #expect(profiles.count == 2)
    #expect(profiles[0]["name"] as? String == "local")
    let api = try #require(profiles[0]["api"] as? [String: Any])
    #expect(api["baseUrl"] as? String == "http://localhost:11434")
    #expect(api["type"] == nil)
  }

  @Test func loginOptionAcceptsCodex() throws {
    let cli = try ScribeCLI.parse(["--login", "codex"])
    #expect(cli.login == .codex)
  }
}
