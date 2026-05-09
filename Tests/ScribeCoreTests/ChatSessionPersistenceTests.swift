import Foundation
import Logging
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
      scribeVersion: "test",
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

    let id = UUID()
    let stem = Date(timeIntervalSince1970: 1_702_000_000)
    let sys = Components.Schemas.ChatMessage(
      role: .system, content: "sys", name: nil, toolCalls: nil, toolCallId: nil)
    try ChatSessionStore.save(
      ChatSessionArchive(
        id: id, createdAt: stem, updatedAt: stem,
        cwd: "/", model: "m", baseURL: nil, scribeVersion: "test", messages: [sys]),
      to: ChatSessionStore.sessionDirectoryURL(sessionId: id, sessionsDirectoryPath: tempRoot.path))

    let files = try ChatSessionStore.listSessionFiles(sessionsDirectoryPath: tempRoot.path)
    #expect(files.count == 1)
  }

  @Test func sessionDirectoryCreatesParentDirs() throws {
    let tempRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let id = UUID()
    let dir = try ChatSessionStore.sessionDirectoryURL(
      sessionId: id, sessionsDirectoryPath: tempRoot.path)
    #expect(dir.lastPathComponent == id.uuidString)
    // Parent root exists, but session subdirectory is created on save
    #expect(FileManager.default.fileExists(atPath: tempRoot.path))
  }

  @Test func listSessionsSkipsNonSessionDirs() throws {
    let tempRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    // Create a directory that is NOT a session dir (no metadata.json)
    let stray = tempRoot.appendingPathComponent("stray", isDirectory: true)
    try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)

    let files = try ChatSessionStore.listSessionFiles(sessionsDirectoryPath: tempRoot.path)
    #expect(files.isEmpty)
  }

  @Test func listSessionsEmpty() throws {
    let tempRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let files = try ChatSessionStore.listSessionFiles(sessionsDirectoryPath: tempRoot.path)
    #expect(files.isEmpty)
  }

  @Test func appendMessagesExtendsMessagesFile() throws {
    let tempRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let id = UUID()
    let stem = Date(timeIntervalSince1970: 1_703_000_000)
    let sys = Components.Schemas.ChatMessage(
      role: .system, content: "sys", name: nil, toolCalls: nil, toolCallId: nil)
    let dir = try ChatSessionStore.sessionDirectoryURL(
      sessionId: id, sessionsDirectoryPath: tempRoot.path)
    try ChatSessionStore.save(
      ChatSessionArchive(
        id: id, createdAt: stem, updatedAt: stem,
        cwd: "/", model: "m", baseURL: nil, scribeVersion: "test", messages: [sys]),
      to: dir)

    let user = Components.Schemas.ChatMessage(
      role: .user, content: "hello", name: nil, toolCalls: nil, toolCallId: nil)
    try ChatSessionStore.appendMessages([user], to: dir)

    let loaded = try ChatSessionStore.load(from: dir)
    #expect(loaded.messages.count == 2)
    #expect(loaded.messages[1].content == "hello")
  }

  @Test func resolveResumeURLMatchesUUIDPrefix() throws {
    let tempRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let id = UUID()
    let stem = Date(timeIntervalSince1970: 1_704_000_000)
    let sys = Components.Schemas.ChatMessage(
      role: .system, content: "sys", name: nil, toolCalls: nil, toolCallId: nil)
    try ChatSessionStore.save(
      ChatSessionArchive(
        id: id, createdAt: stem, updatedAt: stem,
        cwd: "/", model: "m", baseURL: nil, scribeVersion: "test", messages: [sys]),
      to: ChatSessionStore.sessionDirectoryURL(sessionId: id, sessionsDirectoryPath: tempRoot.path))

    let resolved = try ChatSessionStore.resolveResumeURL(
      specifier: id.uuidString, sessionsDirectoryPath: tempRoot.path)
    #expect(resolved.lastPathComponent == id.uuidString)
  }

  @Test func resolveResumeURLThrowsForMissingID() throws {
    let tempRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    #expect(throws: (any Error).self) {
      _ = try ChatSessionStore.resolveResumeURL(
        specifier: "bbbb", sessionsDirectoryPath: tempRoot.path)
    }
  }

  // MARK: - Incremental persist callback

  @Test func incrementalPersistWritesFullArchiveOnFirstCall() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let id = UUID()
    let logger = Logger(label: "test.persist.incremental")
    let persist = ChatSessionStore.makePersistCallback(
      sessionId: id,
      createdAt: Date(),
      model: "test-model",
      baseURL: "http://127.0.0.1:11434",
      scribeVersion: "test",
      persistURL: dir,
      logger: logger
    )

    let sys = Components.Schemas.ChatMessage(
      role: .system, content: "sys", name: nil, toolCalls: nil, toolCallId: nil)
    let user = Components.Schemas.ChatMessage(
      role: .user, content: "hello", name: nil, toolCalls: nil, toolCallId: nil)

    // First call: writes full archive
    persist([sys, user])

    let loaded = try ChatSessionStore.load(from: dir)
    #expect(loaded.messages.count == 2)
    #expect(loaded.messages[1].content == "hello")
  }

  @Test func incrementalPersistAppendsOnlyNewMessagesOnSubsequentCalls() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let id = UUID()
    let logger = Logger(label: "test.persist.incremental2")
    let persist = ChatSessionStore.makePersistCallback(
      sessionId: id,
      createdAt: Date(),
      model: "test-model",
      baseURL: nil,
      scribeVersion: "test",
      persistURL: dir,
      logger: logger
    )

    let sys = Components.Schemas.ChatMessage(
      role: .system, content: "sys")
    let user1 = Components.Schemas.ChatMessage(
      role: .user, content: "q1")
    let asst1 = Components.Schemas.ChatMessage(
      role: .assistant, content: "a1")
    let user2 = Components.Schemas.ChatMessage(
      role: .user, content: "q2")

    // First call: 3 messages
    persist([sys, user1, asst1])

    // Second call: 4 messages — only the 4th should be appended
    persist([sys, user1, asst1, user2])

    let loaded = try ChatSessionStore.load(from: dir)
    #expect(loaded.messages.count == 4)
    #expect(loaded.messages[3].content == "q2")
  }

  @Test func incrementalPersistNoOpWhenNoNewMessages() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let id = UUID()
    let logger = Logger(label: "test.persist.noop")
    let persist = ChatSessionStore.makePersistCallback(
      sessionId: id,
      createdAt: Date(),
      model: "m",
      baseURL: nil,
      scribeVersion: "test",
      persistURL: dir,
      logger: logger
    )

    let msgs: [Components.Schemas.ChatMessage] = [
      .init(role: .system, content: "s"),
      .init(role: .user, content: "u"),
    ]

    // Two calls with same message list
    persist(msgs)
    persist(msgs)

    let loaded = try ChatSessionStore.load(from: dir)
    #expect(loaded.messages.count == 2)  // no duplicates
  }

  @Test func incrementalPersistLoadMetadataReadsCorrectly() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let id = UUID()
    let logger = Logger(label: "test.persist.metadata")
    let persist = ChatSessionStore.makePersistCallback(
      sessionId: id,
      createdAt: Date(),
      model: "test-model",
      baseURL: "http://localhost:11434",
      scribeVersion: "abc123",
      persistURL: dir,
      logger: logger
    )

    persist([.init(role: .system, content: "sys")])

    let meta = try ChatSessionStore.loadMetadata(from: dir)
    #expect(meta.id == id)
    #expect(meta.model == "test-model")
    #expect(meta.baseURL == "http://localhost:11434")
    #expect(meta.scribeVersion == "abc123")
  }
}
