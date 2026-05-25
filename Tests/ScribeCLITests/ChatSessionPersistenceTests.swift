import Foundation
import Logging
import ScribeCore
import SystemPackage
import Testing

@testable import ScribeCLI

@Suite
struct ChatSessionPersistenceTests {
  @Test func roundTripsThroughSaveAndLoad() async throws {
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

    try await ChatSessionStore.saveMetadata(meta, to: FilePath(temp.path))
    try ChatSessionStore.appendMessages(messages, to: FilePath(temp.path))
    defer { try? FileManager.default.removeItem(at: temp) }

    let loadedMeta = try ChatSessionStore.loadMetadata(from: FilePath(temp.path))
    #expect(loadedMeta.id == meta.id)
    #expect(loadedMeta.model == meta.model)

    let loadedMessages = try ChatSessionStore.loadMessages(from: FilePath(temp.path))
    #expect(loadedMessages.count == messages.count)
    #expect(loadedMessages[0].role == .system)
    #expect(loadedMessages[1].content == "hello")
  }

  @Test func listSessionsReadsFromConfiguredDirectory() async throws {
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
    let dir = try await ChatSessionStore.sessionDirectory(
      sessionId: id, sessionsRoot: FilePath(tempRoot.path))
    try await ChatSessionStore.saveMetadata(meta, to: dir)
    try ChatSessionStore.appendMessages([sys], to: dir)

    let files = try await ChatSessionStore.listSessionDirectories(sessionsRoot: FilePath(tempRoot.path))
    #expect(files.count == 1)
  }

  @Test func sessionDirectoryCreatesParentDirs() async throws {
    let tempRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let id = UUID()
    let dir = try await ChatSessionStore.sessionDirectory(
      sessionId: id, sessionsRoot: FilePath(tempRoot.path))
    #expect(dir.lastComponent?.string == id.uuidString)
    #expect(FileManager.default.fileExists(atPath: tempRoot.path))
  }

  @Test func listSessionsSkipsNonSessionDirs() async throws {
    let tempRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let stray = tempRoot.appendingPathComponent("stray", isDirectory: true)
    try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)

    let files = try await ChatSessionStore.listSessionDirectories(sessionsRoot: FilePath(tempRoot.path))
    #expect(files.isEmpty)
  }

  @Test func listSessionsEmpty() async throws {
    let tempRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let files = try await ChatSessionStore.listSessionDirectories(sessionsRoot: FilePath(tempRoot.path))
    #expect(files.isEmpty)
  }

  @Test func appendMessagesExtendsMessagesFile() async throws {
    let tempRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let id = UUID()
    let stem = Date(timeIntervalSince1970: 1_703_000_000)
    let sys = ScribeMessage(
      role: .system, content: "sys")
    let meta = ChatSessionMetadata(
      id: id, createdAt: stem, model: "m", cwd: "/", baseURL: nil, scribeVersion: "test")
    let dir = try await ChatSessionStore.sessionDirectory(
      sessionId: id, sessionsRoot: FilePath(tempRoot.path))
    try await ChatSessionStore.saveMetadata(meta, to: dir)
    try ChatSessionStore.appendMessages([sys], to: dir)

    let user = ScribeMessage(
      role: .user, content: "hello")
    try ChatSessionStore.appendMessages([user], to: dir)

    let loadedMessages = try ChatSessionStore.loadMessages(from: dir)
    #expect(loadedMessages.count == 2)
    #expect(loadedMessages[1].content == "hello")
  }

  @Test func resolveResumeDirectoryMatchesUUIDPrefix() async throws {
    let tempRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let id = UUID()
    let stem = Date(timeIntervalSince1970: 1_704_000_000)
    let sys = ScribeMessage(
      role: .system, content: "sys")
    let meta = ChatSessionMetadata(
      id: id, createdAt: stem, model: "m", cwd: "/", baseURL: nil, scribeVersion: "test")
    let dir = try await ChatSessionStore.sessionDirectory(
      sessionId: id, sessionsRoot: FilePath(tempRoot.path))
    try await ChatSessionStore.saveMetadata(meta, to: dir)
    try ChatSessionStore.appendMessages([sys], to: dir)

    let resolved = try await ChatSessionStore.resolveResumeDirectory(
      specifier: id.uuidString, sessionsRoot: FilePath(tempRoot.path))
    #expect(resolved.lastComponent?.string == id.uuidString)
  }

  @Test func resolveResumeDirectoryThrowsForMissingID() async throws {
    let tempRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    await #expect(throws: (any Error).self) {
      _ = try await ChatSessionStore.resolveResumeDirectory(
        specifier: "bbbb", sessionsRoot: FilePath(tempRoot.path))
    }
  }


  @Test func incrementalPersistWritesMetadataThenAppendsMessages() async throws {
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

    try await ChatSessionStore.saveMetadata(meta, to: FilePath(dir.path))
    try ChatSessionStore.appendMessages([sys, user], to: FilePath(dir.path))

    let loadedMessages = try ChatSessionStore.loadMessages(from: FilePath(dir.path))
    #expect(loadedMessages.count == 2)
    #expect(loadedMessages[1].content == "hello")
  }

  @Test func incrementalPersistAppendsOnlyNewMessages() async throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let sys = ScribeMessage(role: .system, content: "sys")
    let user1 = ScribeMessage(role: .user, content: "q1")
    let asst1 = ScribeMessage(role: .assistant, content: "a1")
    let user2 = ScribeMessage(role: .user, content: "q2")

    // Simulate: persist initial, then append only new
    try ChatSessionStore.appendMessages([sys, user1, asst1], to: FilePath(dir.path))
    try ChatSessionStore.appendMessages([user2], to: FilePath(dir.path))

    let loaded = try ChatSessionStore.loadMessages(from: FilePath(dir.path))
    #expect(loaded.count == 4)
    #expect(loaded[3].content == "q2")
  }


  @Test func forkSessionCopiesPrefixAndLinksParent() async throws {
    let tempRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let parentId = UUID()
    let parentDir = try await ChatSessionStore.sessionDirectory(
      sessionId: parentId, sessionsRoot: FilePath(tempRoot.path))
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
    try await ChatSessionStore.saveMetadata(parentMeta, to: parentDir)
    try ChatSessionStore.appendMessages(messages, to: parentDir)

    let childId = UUID()
    let result = try await ChatSessionStore.forkSession(
      from: parentDir,
      cutAt: 3,
      newSessionId: childId,
      scribeVersion: "child-ver"
    )

    #expect(result.sessionId == childId)
    #expect(result.cutAt == 3)

    let childMeta = try ChatSessionStore.loadMetadata(from: result.sessionDirectory)
    #expect(childMeta.id == childId)
    #expect(childMeta.parentSessionId == parentId)
    #expect(childMeta.forkedAtIndex == 3)
    #expect(childMeta.model == "m")
    #expect(childMeta.scribeVersion == "child-ver")

    let childMessages = try ChatSessionStore.loadMessages(from: result.sessionDirectory)
    #expect(childMessages.count == 3)
    #expect(childMessages[0].role == .system)
    #expect(childMessages[1].content == "q1")
    #expect(childMessages[2].content == "a1")

    // Parent must be untouched.
    let parentMessages = try ChatSessionStore.loadMessages(from: parentDir)
    #expect(parentMessages.count == 5)
  }

  @Test func forkSessionRejectsUnsafeBoundary() async throws {
    let tempRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let parentId = UUID()
    let parentDir = try await ChatSessionStore.sessionDirectory(
      sessionId: parentId, sessionsRoot: FilePath(tempRoot.path))
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
    try await ChatSessionStore.saveMetadata(parentMeta, to: parentDir)
    try ChatSessionStore.appendMessages(messages, to: parentDir)

    // Cut 3 splits between assistant tool_calls and the tool result — not safe.
    await #expect(throws: ScribeError.self) {
      _ = try await ChatSessionStore.forkSession(
        from: parentDir,
        cutAt: 3,
        newSessionId: UUID(),
        scribeVersion: nil
      )
    }
  }

  @Test func incrementalPersistLoadMetadataReadsCorrectly() async throws {
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

    try await ChatSessionStore.saveMetadata(meta, to: FilePath(dir.path))
    try ChatSessionStore.appendMessages(
      [.init(role: .system, content: "sys")], to: FilePath(dir.path))

    let loadedMeta = try ChatSessionStore.loadMetadata(from: FilePath(dir.path))
    #expect(loadedMeta.id == id)
    #expect(loadedMeta.model == "test-model")
    #expect(loadedMeta.baseURL == "http://localhost:11434")
    #expect(loadedMeta.scribeVersion == "abc123")
  }
}
