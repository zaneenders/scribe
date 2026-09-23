import Foundation
import ScribeCore
import SystemPackage
import Testing

@testable import ScribeKit

/// Wave 1B: explicit-path APIs must let one process operate two independent
/// Scribe homes concurrently — without mutating environment variables or the
/// process current directory.
@Suite
struct ExplicitRuntimeIsolationTests {

  private struct Home {
    let root: FilePath
    let paths: ScribePaths
    let context: ScribeRuntimeContext

    init(root: FilePath, modelName: String) throws {
      self.root = root
      self.paths = ScribePaths(dataHome: root)
      try createDirectoryWithIntermediates(root)
      let configJSON = """
        {
          "profiles": [
            {
              "name": "primary",
              "api": { "baseUrl": "http://localhost:11434", "apiKey": "" },
              "agent": {
                "model": "\(modelName)",
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
      self.context = ScribeRuntimeContext(
        paths: paths,
        configurationFile: paths.profileManifestPath,
        defaultWorkingDirectory: root.string,
        version: "isolation-test")
    }
  }

  private func withTwoHomes<T>(_ body: (Home, Home) async throws -> T) async throws -> T {
    let base = FilePath(
      FileManager.default.temporaryDirectory
        .appendingPathComponent("scribe-homes-\(UUID().uuidString)").path)
    let homeA = try Home(root: base.appendingPathComponent("a"), modelName: "model-alpha")
    let homeB = try Home(root: base.appendingPathComponent("b"), modelName: "model-beta")
    defer { try? FileManager.default.removeItem(atPath: base.string) }
    return try await body(homeA, homeB)
  }

  @Test func explicitLoadReadsOnlyTheSuppliedConfiguration() async throws {
    try await withTwoHomes { homeA, homeB in
      let loadedA = try await ConfigLoader.load(
        paths: homeA.paths, configurationFile: homeA.context.configurationFile)
      let loadedB = try await ConfigLoader.load(
        paths: homeB.paths, configurationFile: homeB.context.configurationFile)

      #expect(loadedA.scribeConfig.agentModel == "model-alpha")
      #expect(loadedB.scribeConfig.agentModel == "model-beta")
      #expect(loadedA.paths == homeA.paths)
      #expect(loadedB.paths == homeB.paths)
      #expect(loadedA.resolvedConfigurationPath == homeA.paths.profileManifestPath.string)
      #expect(loadedB.resolvedConfigurationPath == homeB.paths.profileManifestPath.string)
    }
  }

  @Test func explicitBootstrapCreatesSessionsInsideItsOwnHome() async throws {
    try await withTwoHomes { homeA, homeB in
      let sessionA = try await ScribeSessionBootstrap.open(context: homeA.context)
      let sessionB = try await ScribeSessionBootstrap.open(context: homeB.context)

      // Each session directory lives under its own data home.
      #expect(
        sessionA.sessionDirectory.string.hasPrefix(homeA.paths.sessionsDirectory.string))
      #expect(
        sessionB.sessionDirectory.string.hasPrefix(homeB.paths.sessionsDirectory.string))
      #expect(sessionA.sessionId != sessionB.sessionId)

      // Metadata and messages were persisted in the right home.
      let metadataA = try ChatSessionStore.loadMetadata(from: sessionA.sessionDirectory)
      #expect(metadataA.id == sessionA.sessionId)
      #expect(metadataA.model == "model-alpha")
      #expect(metadataA.cwd == homeA.root.string)
      let metadataB = try ChatSessionStore.loadMetadata(from: sessionB.sessionDirectory)
      #expect(metadataB.model == "model-beta")

      let messagesA = try ChatSessionStore.loadMessages(from: sessionA.sessionDirectory)
      #expect(messagesA.first?.role == .system)

      // Listing each home sees only its own session.
      let directoriesA = try await ChatSessionStore.listSessionDirectories(
        sessionsRoot: homeA.paths.sessionsDirectory)
      let directoriesB = try await ChatSessionStore.listSessionDirectories(
        sessionsRoot: homeB.paths.sessionsDirectory)
      #expect(directoriesA == [sessionA.sessionDirectory])
      #expect(directoriesB == [sessionB.sessionDirectory])
    }
  }

  @Test func explicitBootstrapResumesSessionsFromItsOwnHomeOnly() async throws {
    try await withTwoHomes { homeA, homeB in
      let created = try await ScribeSessionBootstrap.open(context: homeA.context)
      try ChatSessionStore.appendMessages(
        [
          ScribeMessage(role: .user, content: "hello"),
          ScribeMessage(role: .assistant, content: "hi"),
        ],
        to: created.sessionDirectory)

      let resumed = try await ScribeSessionBootstrap.open(
        context: homeA.context,
        resumeDirectory: created.sessionDirectory)

      #expect(resumed.sessionId == created.sessionId)
      #expect(resumed.initialMessages.count == 3)
      #expect(resumed.initialMessages.last?.content == "hi")

      // Home B knows nothing about home A's session.
      let listedB = try await ChatSessionStore.listSessionDirectories(
        sessionsRoot: homeB.paths.sessionsDirectory)
      #expect(listedB.isEmpty)
    }
  }

  @Test func resumeLatestUsesContextWorkingDirectory() async throws {
    try await withTwoHomes { homeA, _ in
      _ = try await ScribeSessionBootstrap.open(context: homeA.context)
      let second = try await ScribeSessionBootstrap.open(context: homeA.context)
      // Metadata timestamps round-trip at second precision, so pin the second
      // session explicitly to a strictly newer last-message date.
      var metadata = try ChatSessionStore.loadMetadata(from: second.sessionDirectory)
      metadata.lastMessageAt = Date(timeIntervalSinceNow: 60)
      try await ChatSessionStore.saveMetadata(metadata, to: second.sessionDirectory)

      // "latest" resolves within home A's sessions root using the context cwd.
      let resumed = try await ScribeSessionBootstrap.open(
        context: homeA.context, resumeLatest: true)
      #expect(resumed.sessionId == second.sessionId)
      #expect(resumed.workingDirectory == homeA.context.defaultWorkingDirectory)
    }
  }

  @Test func resolvePathsExplicitUsesGivenManifestAndNeverTheEnvironment() async throws {
    try await withTwoHomes { homeA, homeB in
      // An explicit configuration file wins even when a manifest exists.
      let customConfig = homeA.root.appendingPathComponent("custom.json")
      try
        #"{"profiles":[{"name":"custom","api":{"baseUrl":"http://x","apiKey":""},"agent":{"model":"custom-model","contextWindow":1000,"contextWindowThreshold":0.5},"logging":{"level":"trace"}}}]}"#
        .write(toFile: customConfig.string, atomically: true, encoding: .utf8)
      let resolved = try ConfigLoader.resolvePaths(
        paths: homeB.paths, configurationFile: customConfig)
      #expect(resolved.configPath == customConfig)
      #expect(resolved.paths == homeB.paths)

      // Nil configuration file falls back to the home's own manifest.
      let resolvedA = try ConfigLoader.resolvePaths(paths: homeA.paths, configurationFile: nil)
      #expect(resolvedA.configPath == homeA.paths.profileManifestPath)
      let resolvedB = try ConfigLoader.resolvePaths(paths: homeB.paths, configurationFile: nil)
      #expect(resolvedB.configPath == homeB.paths.profileManifestPath)
    }
  }

  @Test func resolvePathsExplicitWritesDefaultOnlyInsideSuppliedPaths() async throws {
    try await withTemporaryDirectory { root in
      let paths = ScribePaths(dataHome: FilePath(root.path))
      // No manifest exists; explicit resolution writes the default there.
      let resolved = try ConfigLoader.resolvePaths(paths: paths, configurationFile: nil)
      #expect(resolved.configPath == paths.profileManifestPath)
      #expect(FileStat.stat(paths.profileManifestPath).exists)

      // The written default loads and points at the local provider.
      let loaded = try await ConfigLoader.load(paths: paths)
      #expect(loaded.profiles.count == 1)
      #expect(loaded.activeProfileName == "local")
    }
  }

  @Test func runtimeContextCarriesExplicitInputs() throws {
    let base = FilePath(
      FileManager.default.temporaryDirectory
        .appendingPathComponent("scribe-homes-\(UUID().uuidString)").path)
    let homeA = try Home(root: base.appendingPathComponent("a"), modelName: "model-alpha")
    defer { try? FileManager.default.removeItem(atPath: base.string) }

    let context = homeA.context
    #expect(context.paths == homeA.paths)
    #expect(context.configurationFile == homeA.paths.profileManifestPath)
    #expect(context.defaultWorkingDirectory == homeA.root.string)
    #expect(context.version == "isolation-test")

    let equivalent = ScribeRuntimeContext(
      paths: context.paths,
      configurationFile: context.configurationFile,
      defaultWorkingDirectory: context.defaultWorkingDirectory,
      version: context.version)
    #expect(equivalent == context)
  }
}
