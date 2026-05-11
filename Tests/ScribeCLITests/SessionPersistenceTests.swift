import Foundation
import ScribeCore
import ScribeLLM
import Testing

@testable import ScribeCLI

@Suite
struct SessionPersistenceTests {

  @Test func writeMetadataOnceWritesOnlyFirstTime() async throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let id = UUID()
    let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
    let persistence = SessionPersistence(url: dir, sessionId: id, createdAt: createdAt)

    // First write should succeed.
    try await persistence.writeMetadataOnce(model: "test-model", cwd: "/tmp", baseURL: "http://localhost")
    let meta1 = try ChatSessionStore.loadMetadata(from: dir)
    #expect(meta1.id == id)
    #expect(meta1.model == "test-model")

    // Second write with different model should be a no-op.
    try await persistence.writeMetadataOnce(model: "other-model", cwd: "/other", baseURL: "http://other")
    let meta2 = try ChatSessionStore.loadMetadata(from: dir)
    #expect(meta2.model == "test-model")  // unchanged
  }

  @Test func appendMessagesPersistsIncrementally() async throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let id = UUID()
    let persistence = SessionPersistence(url: dir, sessionId: id, createdAt: Date())

    let sys = Components.Schemas.ChatMessage(role: .system, content: "sys")
    let user = Components.Schemas.ChatMessage(role: .user, content: "hello")

    // First append
    try await persistence.append([sys])
    var loaded = try ChatSessionStore.loadMessages(from: dir)
    #expect(loaded.count == 1)

    // Second append
    try await persistence.append([user])
    loaded = try ChatSessionStore.loadMessages(from: dir)
    #expect(loaded.count == 2)
    #expect(loaded[1].content == "hello")
  }

  @Test func appendMessagesHandlesEmptyArray() async throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let persistence = SessionPersistence(url: dir, sessionId: UUID(), createdAt: Date())

    // Appending empty array should not crash or create a corrupt file.
    try await persistence.append([])
    let loaded = try ChatSessionStore.loadMessages(from: dir)
    #expect(loaded.isEmpty)
  }

  @Test func sessionIdAndCreatedAtAreExposed() async {
    let id = UUID()
    let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
    let persistence = SessionPersistence(
      url: FileManager.default.temporaryDirectory,
      sessionId: id,
      createdAt: createdAt
    )
    #expect(persistence.sessionId == id)
    #expect(persistence.createdAt == createdAt)
  }
}
