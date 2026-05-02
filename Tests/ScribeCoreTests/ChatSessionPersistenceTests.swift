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
}
