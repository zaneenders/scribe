import Foundation
import Logging
import ScribeCore
import Testing

@testable import ScribeCLI

@Suite
struct ChatSessionPersistenceTests {
  @Test func roundTripsThroughSaveAndLoad() throws {
    let id = UUID()
    let stamp = Date(timeIntervalSince1970: 1_700_000_000)
    let messages: [ScribeMessage] = [
      ScribeMessage(role: .system, content: "sys"),
      ScribeMessage(role: .user, content: "hello"),
    ]
    let meta = ChatSessionMetadata(
      id: id,
      createdAt: stamp,
      model: "test-model",
      cwd: "/tmp/scribe",
      baseURL: "http://127.0.0.1:11434",
      scribeVersion: "test"
    )

    let temp = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)

    try ChatSessionStore.saveMetadata(meta, to: temp)
    try ChatSessionStore.appendMessages(messages, to: temp)
    defer { try? FileManager.default.removeItem(at: temp) }

    let loadedMeta = try ChatSessionStore.loadMetadata(from: temp)
    #expect(loadedMeta.id == meta.id)
    #expect(loadedMeta.model == meta.model)

    let loadedMessages = try ChatSessionStore.loadMessages(from: temp)
    #expect(loadedMessages.count == messages.count)
    #expect(loadedMessages[0].role == .system)
    #expect(loadedMessages[1].content == "hello")
  }

  @Test func listSessionsReadsFromConfiguredDirectory() throws {
    let tempRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let id = UUID()
    let stem = Date(timeIntervalSince1970: 1_702_000_000)
    let sys = ScribeMessage(
      role: .system, content: "sys")
    let meta = ChatSessionMetadata(
      id: id, createdAt: stem, model: "m", cwd: "/", baseURL: nil, scribeVersion: "test")
    let dir = try ChatSessionStore.sessionDirectoryURL(
      sessionId: id, sessionsDirectoryPath: tempRoot.path)
    try ChatSessionStore.saveMetadata(meta, to: dir)
    try ChatSessionStore.appendMessages([sys], to: dir)

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
    #expect(FileManager.default.fileExists(atPath: tempRoot.path))
  }

  @Test func listSessionsSkipsNonSessionDirs() throws {
    let tempRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

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
    let sys = ScribeMessage(
      role: .system, content: "sys")
    let meta = ChatSessionMetadata(
      id: id, createdAt: stem, model: "m", cwd: "/", baseURL: nil, scribeVersion: "test")
    let dir = try ChatSessionStore.sessionDirectoryURL(
      sessionId: id, sessionsDirectoryPath: tempRoot.path)
    try ChatSessionStore.saveMetadata(meta, to: dir)
    try ChatSessionStore.appendMessages([sys], to: dir)

    let user = ScribeMessage(
      role: .user, content: "hello")
    try ChatSessionStore.appendMessages([user], to: dir)

    let loadedMessages = try ChatSessionStore.loadMessages(from: dir)
    #expect(loadedMessages.count == 2)
    #expect(loadedMessages[1].content == "hello")
  }

  @Test func resolveResumeURLMatchesUUIDPrefix() throws {
    let tempRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let id = UUID()
    let stem = Date(timeIntervalSince1970: 1_704_000_000)
    let sys = ScribeMessage(
      role: .system, content: "sys")
    let meta = ChatSessionMetadata(
      id: id, createdAt: stem, model: "m", cwd: "/", baseURL: nil, scribeVersion: "test")
    let dir = try ChatSessionStore.sessionDirectoryURL(
      sessionId: id, sessionsDirectoryPath: tempRoot.path)
    try ChatSessionStore.saveMetadata(meta, to: dir)
    try ChatSessionStore.appendMessages([sys], to: dir)

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

  // MARK: - Incremental persist

  @Test func incrementalPersistWritesMetadataThenAppendsMessages() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let id = UUID()
    let meta = ChatSessionMetadata(
      id: id,
      createdAt: Date(),
      model: "test-model",
      cwd: "/tmp",
      baseURL: "http://127.0.0.1:11434",
      scribeVersion: "test"
    )

    let sys = ScribeMessage(
      role: .system, content: "sys")
    let user = ScribeMessage(
      role: .user, content: "hello")

    try ChatSessionStore.saveMetadata(meta, to: dir)
    try ChatSessionStore.appendMessages([sys, user], to: dir)

    let loadedMessages = try ChatSessionStore.loadMessages(from: dir)
    #expect(loadedMessages.count == 2)
    #expect(loadedMessages[1].content == "hello")
  }

  @Test func incrementalPersistAppendsOnlyNewMessages() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let sys = ScribeMessage(role: .system, content: "sys")
    let user1 = ScribeMessage(role: .user, content: "q1")
    let asst1 = ScribeMessage(role: .assistant, content: "a1")
    let user2 = ScribeMessage(role: .user, content: "q2")

    // Simulate: persist initial, then append only new
    try ChatSessionStore.appendMessages([sys, user1, asst1], to: dir)
    try ChatSessionStore.appendMessages([user2], to: dir)

    let loaded = try ChatSessionStore.loadMessages(from: dir)
    #expect(loaded.count == 4)
    #expect(loaded[3].content == "q2")
  }

  // MARK: - Fork

  @Test func forkSessionCopiesPrefixAndLinksParent() throws {
    let tempRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let parentId = UUID()
    let parentDir = try ChatSessionStore.sessionDirectoryURL(
      sessionId: parentId, sessionsDirectoryPath: tempRoot.path)
    let parentMeta = ChatSessionMetadata(
      id: parentId,
      createdAt: Date(),
      model: "m",
      cwd: "/tmp",
      baseURL: "http://x",
      scribeVersion: "parent-ver"
    )
    let messages: [ScribeMessage] = [
      ScribeMessage(role: .system, content: "sys"),
      ScribeMessage(role: .user, content: "q1"),
      ScribeMessage(role: .assistant, content: "a1"),
      ScribeMessage(role: .user, content: "q2"),
      ScribeMessage(role: .assistant, content: "a2"),
    ]
    try ChatSessionStore.saveMetadata(parentMeta, to: parentDir)
    try ChatSessionStore.appendMessages(messages, to: parentDir)

    let childId = UUID()
    let result = try ChatSessionStore.forkSession(
      from: parentDir,
      cutAt: 3,
      newSessionId: childId,
      scribeVersion: "child-ver"
    )

    #expect(result.sessionId == childId)
    #expect(result.cutAt == 3)

    let childMeta = try ChatSessionStore.loadMetadata(from: result.sessionURL)
    #expect(childMeta.id == childId)
    #expect(childMeta.parentSessionId == parentId)
    #expect(childMeta.forkedAtIndex == 3)
    #expect(childMeta.model == "m")
    #expect(childMeta.scribeVersion == "child-ver")

    let childMessages = try ChatSessionStore.loadMessages(from: result.sessionURL)
    #expect(childMessages.count == 3)
    #expect(childMessages[0].role == .system)
    #expect(childMessages[1].content == "q1")
    #expect(childMessages[2].content == "a1")

    // Parent must be untouched.
    let parentMessages = try ChatSessionStore.loadMessages(from: parentDir)
    #expect(parentMessages.count == 5)
  }

  @Test func forkSessionRejectsUnsafeBoundary() throws {
    let tempRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let parentId = UUID()
    let parentDir = try ChatSessionStore.sessionDirectoryURL(
      sessionId: parentId, sessionsDirectoryPath: tempRoot.path)
    let parentMeta = ChatSessionMetadata(
      id: parentId, createdAt: Date(), model: "m", cwd: "/", baseURL: nil, scribeVersion: nil)
    let messages: [ScribeMessage] = [
      ScribeMessage(role: .system, content: "sys"),
      ScribeMessage(role: .user, content: "q"),
      ScribeMessage(
        role: .assistant, content: "",
        toolCalls: [ScribeToolCall(id: "c1", name: "x", arguments: "{}")]),
      ScribeMessage(role: .tool, content: "ok", toolCallId: "c1"),
    ]
    try ChatSessionStore.saveMetadata(parentMeta, to: parentDir)
    try ChatSessionStore.appendMessages(messages, to: parentDir)

    // Cut 3 splits between assistant tool_calls and the tool result — not safe.
    #expect(throws: ScribeError.self) {
      _ = try ChatSessionStore.forkSession(
        from: parentDir,
        cutAt: 3,
        newSessionId: UUID(),
        scribeVersion: nil
      )
    }
  }

  @Test func incrementalPersistLoadMetadataReadsCorrectly() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let id = UUID()
    let meta = ChatSessionMetadata(
      id: id,
      createdAt: Date(),
      model: "test-model",
      cwd: "/tmp",
      baseURL: "http://localhost:11434",
      scribeVersion: "abc123"
    )

    try ChatSessionStore.saveMetadata(meta, to: dir)
    try ChatSessionStore.appendMessages(
      [.init(role: .system, content: "sys")], to: dir)

    let loadedMeta = try ChatSessionStore.loadMetadata(from: dir)
    #expect(loadedMeta.id == id)
    #expect(loadedMeta.model == "test-model")
    #expect(loadedMeta.baseURL == "http://localhost:11434")
    #expect(loadedMeta.scribeVersion == "abc123")
  }
}
