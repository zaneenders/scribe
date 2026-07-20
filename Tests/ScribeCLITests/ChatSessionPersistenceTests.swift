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

  @Test func inlineImageDataIsStoredAsExternalAttachment() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let imageData = Data([0x89, 0x50, 0x4E, 0x47, 0x01, 0x02, 0x03])
    let dataURI = "data:image/png;base64,\(imageData.base64EncodedString())"
    let message = ScribeMessage(
      role: .user,
      contentParts: [.text("image:"), .image(url: dataURI, detail: "high")])

    try ChatSessionStore.appendMessages([message], to: FilePath(directory.path))

    let messagesData = try Data(
      contentsOf: directory.appendingPathComponent("messages.jsonl"))
    let persisted = String(decoding: messagesData, as: UTF8.self)
    #expect(persisted.contains(#""type":"image_ref""#))
    #expect(persisted.contains(#""mime_type":"image\/png""#))
    #expect(!persisted.contains("base64"))
    #expect(!persisted.contains(imageData.base64EncodedString()))

    let attachmentDirectory = directory.appendingPathComponent("attachments", isDirectory: true)
    let attachmentNames = try FileManager.default.contentsOfDirectory(atPath: attachmentDirectory.path)
    #expect(attachmentNames.count == 1)
    let storedData = try Data(
      contentsOf: attachmentDirectory.appendingPathComponent(attachmentNames[0]))
    #expect(storedData == imageData)

    let loaded = try ChatSessionStore.loadMessages(from: FilePath(directory.path))
    #expect(loaded.count == 1)
    #expect(loaded[0].contentParts == message.contentParts)
  }

  @Test func legacyInlineImageSessionsStillLoad() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let dataURI = "data:image/png;base64,AQID"
    let message = ScribeMessage(
      role: .user, contentParts: [.image(url: dataURI, detail: nil)])
    var encoded = try JSONEncoder().encode(message)
    encoded.append(UInt8(ascii: "\n"))
    try encoded.write(to: directory.appendingPathComponent("messages.jsonl"))

    let loaded = try ChatSessionStore.loadMessages(from: FilePath(directory.path))
    #expect(loaded.count == 1)
    #expect(loaded[0].contentParts == message.contentParts)
  }

  @Test func remoteImageURLsRemainInlineReferences() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let imageURL = "https://example.com/image.png"
    let message = ScribeMessage(
      role: .user, contentParts: [.image(url: imageURL, detail: "low")])
    try ChatSessionStore.appendMessages([message], to: FilePath(directory.path))

    let persisted = try String(
      contentsOf: directory.appendingPathComponent("messages.jsonl"), encoding: .utf8)
    #expect(persisted.contains("example.com"))
    #expect(persisted.contains(#""type":"image_url""#))
    #expect(
      !FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("attachments").path))

    let loaded = try ChatSessionStore.loadMessages(from: FilePath(directory.path))
    #expect(loaded[0].contentParts == message.contentParts)
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
