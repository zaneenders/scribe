import Foundation
import ScribeCore
import ScribeLLM
import Testing

@Suite
struct ChatSessionPersistenceTests {
  @Test func archiveRoundTripsThroughSaveAndLoad() throws {
    let id = UUID()
    let stamp = Date(timeIntervalSince1970: 1_700_000_000)
    let messages: [Components.Schemas.ChatMessage] = [
      .init(role: .system, content: "sys", name: nil, toolCalls: nil, toolCallId: nil),
      .init(role: .user, content: "hello", name: nil, toolCalls: nil, toolCallId: nil),
    ]
    let original = ChatSessionArchive(
      id: id,
      createdAt: stamp,
      updatedAt: stamp,
      cwd: "/tmp/scribe",
      model: "test-model",
      baseURL: "http://127.0.0.1:11434",
      messages: messages
    )

    let temp = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: false)
      .appendingPathExtension("json")

    try ChatSessionStore.save(original, to: temp)
    defer { try? FileManager.default.removeItem(at: temp) }

    let loaded = try ChatSessionStore.load(from: temp)
    #expect(loaded.id == original.id)
    #expect(loaded.model == original.model)
    #expect(loaded.messages.count == original.messages.count)
    #expect(loaded.messages[0].role == .system)
    #expect(loaded.messages[1].content == "hello")
  }

  @Test func listSessionsReadsFromConfiguredDirectory() throws {
    let tempRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let config = AgentConfig(
      openAIBaseURL: "http://127.0.0.1:1",
      openAIAPIKey: nil,
      agentModel: "m",
      agentMaxToolRounds: 8,
      logLevel: .info,
      logDirectoryPath: tempRoot.path,
      chatSessionsDirectoryPath: tempRoot.path,
      resolvedConfigurationPath: "/dev/null"
    )

    let id = UUID()
    let stem = Date(timeIntervalSince1970: 1_702_000_000)
    let archive = ChatSessionArchive(
      id: id,
      createdAt: stem,
      updatedAt: stem,
      cwd: "/tmp",
      model: "m",
      baseURL: nil,
      messages: [
        .init(role: .system, content: "s", name: nil, toolCalls: nil, toolCallId: nil)
      ]
    )
    let fileURL = try ChatSessionStore.fileURL(sessionId: id, configuration: config)
    try ChatSessionStore.save(archive, to: fileURL)

    let listed = try ChatSessionStore.listSessionFiles(configuration: config)
    let wantPath = fileURL.standardizedFileURL.resolvingSymlinksInPath().path
    #expect(listed.contains { $0.standardizedFileURL.resolvingSymlinksInPath().path == wantPath })
  }

  @Test func loadRejectsArchiveWithoutSystemMessage() throws {
    let messages: [Components.Schemas.ChatMessage] = [
      .init(role: .user, content: "no system", name: nil, toolCalls: nil, toolCallId: nil)
    ]
    let bad = ChatSessionArchive(
      id: UUID(),
      createdAt: Date(),
      updatedAt: Date(),
      cwd: "/",
      model: "x",
      baseURL: nil,
      messages: messages
    )
    let temp = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: false)
      .appendingPathExtension("json")

    try ChatSessionStore.save(bad, to: temp)
    defer { try? FileManager.default.removeItem(at: temp) }

    #expect(throws: (any Error).self) {
      _ = try ChatSessionStore.load(from: temp)
    }
  }

  // MARK: - resolveResumeURL

  @Test func resolveResumeURLLatestPicksMostRecentFile() throws {
    let tempRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let config = AgentConfig(
      openAIBaseURL: "http://127.0.0.1:1",
      openAIAPIKey: nil,
      agentModel: "m",
      agentMaxToolRounds: 8,
      logLevel: .info,
      logDirectoryPath: tempRoot.path,
      chatSessionsDirectoryPath: tempRoot.path,
      resolvedConfigurationPath: "/dev/null"
    )

    // Create two sessions, one older and one newer.
    let olderId = UUID()
    let newerId = UUID()
    let base = Date(timeIntervalSince1970: 1_702_000_000)
    let older = ChatSessionArchive(
      id: olderId, createdAt: base, updatedAt: base,
      cwd: "/", model: "m", baseURL: nil,
      messages: [.init(role: .system, content: "old", name: nil, toolCalls: nil, toolCallId: nil)]
    )
    let newer = ChatSessionArchive(
      id: newerId, createdAt: base + 1000, updatedAt: base + 1000,
      cwd: "/", model: "m", baseURL: nil,
      messages: [.init(role: .system, content: "new", name: nil, toolCalls: nil, toolCallId: nil)]
    )
    let olderURL = try ChatSessionStore.fileURL(sessionId: olderId, configuration: config)
    let newerURL = try ChatSessionStore.fileURL(sessionId: newerId, configuration: config)
    try ChatSessionStore.save(older, to: olderURL)
    // Small sleep to ensure modification time differs.
    Thread.sleep(forTimeInterval: 0.1)
    try ChatSessionStore.save(newer, to: newerURL)

    let resolved = try ChatSessionStore.resolveResumeURL(specifier: "latest", configuration: config)
    #expect(resolved.lastPathComponent == "\(newerId.uuidString).json")
  }

  @Test func resolveResumeURLLatestThrowsWhenNoSessions() throws {
    let tempRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let config = AgentConfig(
      openAIBaseURL: "http://127.0.0.1:1",
      openAIAPIKey: nil,
      agentModel: "m",
      agentMaxToolRounds: 8,
      logLevel: .info,
      logDirectoryPath: tempRoot.path,
      chatSessionsDirectoryPath: tempRoot.path,
      resolvedConfigurationPath: "/dev/null"
    )

    #expect(throws: (any Error).self) {
      _ = try ChatSessionStore.resolveResumeURL(specifier: "latest", configuration: config)
    }
  }

  @Test func resolveResumeURLByUUIDString() throws {
    let tempRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let config = AgentConfig(
      openAIBaseURL: "http://127.0.0.1:1",
      openAIAPIKey: nil,
      agentModel: "m",
      agentMaxToolRounds: 8,
      logLevel: .info,
      logDirectoryPath: tempRoot.path,
      chatSessionsDirectoryPath: tempRoot.path,
      resolvedConfigurationPath: "/dev/null"
    )

    let targetId = UUID()
    let archive = ChatSessionArchive(
      id: targetId, createdAt: Date(), updatedAt: Date(),
      cwd: "/", model: "m", baseURL: nil,
      messages: [.init(role: .system, content: "s", name: nil, toolCalls: nil, toolCallId: nil)]
    )
    let _ = try ChatSessionStore.fileURL(sessionId: targetId, configuration: config)
    try ChatSessionStore.save(archive, to: ChatSessionStore.fileURL(sessionId: targetId, configuration: config))

    let resolved = try ChatSessionStore.resolveResumeURL(
      specifier: targetId.uuidString, configuration: config)
    #expect(resolved.lastPathComponent == "\(targetId.uuidString).json")
  }

  @Test func resolveResumeURLByPrefix() throws {
    let tempRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let config = AgentConfig(
      openAIBaseURL: "http://127.0.0.1:1",
      openAIAPIKey: nil,
      agentModel: "m",
      agentMaxToolRounds: 8,
      logLevel: .info,
      logDirectoryPath: tempRoot.path,
      chatSessionsDirectoryPath: tempRoot.path,
      resolvedConfigurationPath: "/dev/null"
    )

    let targetId = UUID(uuidString: "AAAA0000-0000-0000-0000-000000000001")!
    let archive = ChatSessionArchive(
      id: targetId, createdAt: Date(), updatedAt: Date(),
      cwd: "/", model: "m", baseURL: nil,
      messages: [.init(role: .system, content: "s", name: nil, toolCalls: nil, toolCallId: nil)]
    )
    try ChatSessionStore.save(
      archive, to: ChatSessionStore.fileURL(sessionId: targetId, configuration: config))

    let resolved = try ChatSessionStore.resolveResumeURL(
      specifier: "aaaa0000", configuration: config)
    #expect(resolved.lastPathComponent == "\(targetId.uuidString).json")
  }

  @Test func resolveResumeURLByPath() throws {
    let tempRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let config = AgentConfig(
      openAIBaseURL: "http://127.0.0.1:1",
      openAIAPIKey: nil,
      agentModel: "m",
      agentMaxToolRounds: 8,
      logLevel: .info,
      logDirectoryPath: tempRoot.path,
      chatSessionsDirectoryPath: tempRoot.path,
      resolvedConfigurationPath: "/dev/null"
    )

    let targetId = UUID()
    let archive = ChatSessionArchive(
      id: targetId, createdAt: Date(), updatedAt: Date(),
      cwd: "/", model: "m", baseURL: nil,
      messages: [.init(role: .system, content: "s", name: nil, toolCalls: nil, toolCallId: nil)]
    )
    let fileURL = try ChatSessionStore.fileURL(sessionId: targetId, configuration: config)
    try ChatSessionStore.save(archive, to: fileURL)

    // Resolve by full path
    let resolved = try ChatSessionStore.resolveResumeURL(
      specifier: fileURL.path, configuration: config)
    #expect(resolved.standardizedFileURL.path == fileURL.standardizedFileURL.path)
  }

  @Test func resolveResumeURLThrowsForEmptySpecifier() {
    let config = AgentConfig(
      openAIBaseURL: "http://127.0.0.1:1",
      openAIAPIKey: nil,
      agentModel: "m",
      agentMaxToolRounds: 8,
      logLevel: .info,
      logDirectoryPath: "/tmp",
      chatSessionsDirectoryPath: "/tmp",
      resolvedConfigurationPath: "/dev/null"
    )

    #expect(throws: (any Error).self) {
      _ = try ChatSessionStore.resolveResumeURL(specifier: "   ", configuration: config)
    }
  }

  @Test func resolveResumeURLThrowsForAmbiguousPrefix() throws {
    let tempRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let config = AgentConfig(
      openAIBaseURL: "http://127.0.0.1:1",
      openAIAPIKey: nil,
      agentModel: "m",
      agentMaxToolRounds: 8,
      logLevel: .info,
      logDirectoryPath: tempRoot.path,
      chatSessionsDirectoryPath: tempRoot.path,
      resolvedConfigurationPath: "/dev/null"
    )

    // Create two sessions sharing a common prefix
    let id1 = UUID(uuidString: "BBBB0000-0000-0000-0000-000000000001")!
    let id2 = UUID(uuidString: "BBBB0000-0000-0000-0000-000000000002")!
    let sys = Components.Schemas.ChatMessage(
      role: .system, content: "s", name: nil, toolCalls: nil, toolCallId: nil)
    for id in [id1, id2] {
      let archive = ChatSessionArchive(
        id: id, createdAt: Date(), updatedAt: Date(),
        cwd: "/", model: "m", baseURL: nil, messages: [sys])
      try ChatSessionStore.save(
        archive, to: ChatSessionStore.fileURL(sessionId: id, configuration: config))
    }

    #expect(throws: (any Error).self) {
      _ = try ChatSessionStore.resolveResumeURL(specifier: "bbbb", configuration: config)
    }
  }
}
