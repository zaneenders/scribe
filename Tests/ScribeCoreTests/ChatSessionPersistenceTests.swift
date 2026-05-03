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
      .appendingPathComponent(UUID().uuidString, isDirectory: true)

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
      contextWindow: 128000,
      contextWindowThreshold: 0.8,
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
    let dirURL = try ChatSessionStore.sessionDirectoryURL(sessionId: id, configuration: config)
    try ChatSessionStore.save(archive, to: dirURL)

    let listed = try ChatSessionStore.listSessionFiles(configuration: config)
    let wantPath = dirURL.standardizedFileURL.resolvingSymlinksInPath().path
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
      .appendingPathComponent(UUID().uuidString, isDirectory: true)

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
      contextWindow: 128000,
      contextWindowThreshold: 0.8,
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
    let olderURL = try ChatSessionStore.sessionDirectoryURL(sessionId: olderId, configuration: config)
    let newerURL = try ChatSessionStore.sessionDirectoryURL(sessionId: newerId, configuration: config)
    try ChatSessionStore.save(older, to: olderURL)
    // Small sleep to ensure modification time differs.
    Thread.sleep(forTimeInterval: 0.1)
    try ChatSessionStore.save(newer, to: newerURL)

    let resolved = try ChatSessionStore.resolveResumeURL(specifier: "latest", configuration: config)
    #expect(resolved.lastPathComponent == newerId.uuidString)
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
      contextWindow: 128000,
      contextWindowThreshold: 0.8,
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
      contextWindow: 128000,
      contextWindowThreshold: 0.8,
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
    let dirURL = try ChatSessionStore.sessionDirectoryURL(sessionId: targetId, configuration: config)
    try ChatSessionStore.save(archive, to: dirURL)

    let resolved = try ChatSessionStore.resolveResumeURL(
      specifier: targetId.uuidString, configuration: config)
    #expect(resolved.lastPathComponent == targetId.uuidString)
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
      contextWindow: 128000,
      contextWindowThreshold: 0.8,
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
      archive, to: ChatSessionStore.sessionDirectoryURL(sessionId: targetId, configuration: config))

    let resolved = try ChatSessionStore.resolveResumeURL(
      specifier: "aaaa0000", configuration: config)
    #expect(resolved.lastPathComponent == targetId.uuidString)
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
      contextWindow: 128000,
      contextWindowThreshold: 0.8,
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
    let dirURL = try ChatSessionStore.sessionDirectoryURL(sessionId: targetId, configuration: config)
    try ChatSessionStore.save(archive, to: dirURL)

    // Resolve by full path
    let resolved = try ChatSessionStore.resolveResumeURL(
      specifier: dirURL.path, configuration: config)
    #expect(resolved.standardizedFileURL.path == dirURL.standardizedFileURL.path)
  }

  @Test func resolveResumeURLThrowsForEmptySpecifier() {
    let config = AgentConfig(
      openAIBaseURL: "http://127.0.0.1:1",
      openAIAPIKey: nil,
      agentModel: "m",
      agentMaxToolRounds: 8,
      contextWindow: 128000,
      contextWindowThreshold: 0.8,
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
      contextWindow: 128000,
      contextWindowThreshold: 0.8,
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
        archive, to: ChatSessionStore.sessionDirectoryURL(sessionId: id, configuration: config))
    }

    #expect(throws: (any Error).self) {
      _ = try ChatSessionStore.resolveResumeURL(specifier: "bbbb", configuration: config)
    }
  }

  // MARK: - Incremental JSONL persistence

  @Test func appendMessagesCreatesJsonlInsideDirectory() throws {
    let temp = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }

    let archive = ChatSessionArchive(
      id: UUID(), createdAt: Date(), updatedAt: Date(),
      cwd: "/tmp", model: "m", baseURL: nil,
      messages: [.init(role: .system, content: "sys", name: nil, toolCalls: nil, toolCallId: nil)]
    )
    try ChatSessionStore.save(archive, to: temp)

    let newMessages: [Components.Schemas.ChatMessage] = [
      .init(role: .user, content: "hello", name: nil, toolCalls: nil, toolCallId: nil),
      .init(role: .assistant, content: "hi", name: nil, toolCalls: nil, toolCallId: nil),
    ]
    try ChatSessionStore.appendMessages(newMessages, to: temp)

    let jsonlURL = temp.appendingPathComponent("messages.jsonl", isDirectory: false)
    #expect(FileManager.default.fileExists(atPath: jsonlURL.path))

    let data = try Data(contentsOf: jsonlURL)
    let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
    #expect(lines.count == 3)
  }

  @Test func loadIgnoresPartialTrailingLineInMessagesJsonl() throws {
    let temp = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }

    let archive = ChatSessionArchive(
      id: UUID(), createdAt: Date(), updatedAt: Date(),
      cwd: "/tmp", model: "m", baseURL: nil,
      messages: [.init(role: .system, content: "sys", name: nil, toolCalls: nil, toolCallId: nil)]
    )
    try ChatSessionStore.save(archive, to: temp)

    let jsonlURL = temp.appendingPathComponent("messages.jsonl", isDirectory: false)
    let validLine = try JSONEncoder().encode(
      Components.Schemas.ChatMessage(role: .user, content: "ok", name: nil, toolCalls: nil, toolCallId: nil)
    )
    let handle = try FileHandle(forWritingTo: jsonlURL)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: validLine + Data([UInt8(ascii: "\n")]) + Data("{bad json".utf8))

    let merged = try ChatSessionStore.load(from: temp)
    #expect(merged.messages.count == 2)
    #expect(merged.messages[1].content == "ok")
  }

  @Test func appendMessagesUpdatesDirectoryModificationTime() throws {
    let temp = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }

    let archive = ChatSessionArchive(
      id: UUID(), createdAt: Date(), updatedAt: Date(),
      cwd: "/tmp", model: "m", baseURL: nil,
      messages: [.init(role: .system, content: "sys", name: nil, toolCalls: nil, toolCallId: nil)]
    )
    try ChatSessionStore.save(archive, to: temp)

    let before = try temp.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
    Thread.sleep(forTimeInterval: 0.15)

    let newMessage = Components.Schemas.ChatMessage(
      role: .user, content: "hello", name: nil, toolCalls: nil, toolCallId: nil)
    try ChatSessionStore.appendMessages([newMessage], to: temp)

    let after = try temp.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
    #expect(after >= before)
  }
}
