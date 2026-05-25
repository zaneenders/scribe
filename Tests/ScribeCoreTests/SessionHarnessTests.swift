import Foundation
import Logging
import ScribeCore
import SystemPackage
import Synchronization
import Testing

@Suite
struct SessionHarnessTests {

  private let logger = Logger(label: "test.session-harness")

  private func makeHarness(
    seed: [ScribeMessage] = [],
    persister: (any SessionPersister)? = nil
  ) throws -> SessionHarness {
    let sessionId = UUID()
    var document = SessionDocument(
      sessionId: sessionId,
      directory: FilePath("/in-memory/\(sessionId.uuidString)"),
      logger: logger
    )
    if !seed.isEmpty {
      document.append(seed)
    }
    return try SessionHarness(
      configuration: .testValue,
      document: consume document,
      persister: persister ?? InMemorySessionPersister(),
      logger: logger
    )
  }

  @Test func snapshotReflectsDocument() async throws {
    let harness = try makeHarness(seed: [
      ScribeMessage(role: .system, content: "sys"),
      ScribeMessage(role: .user, content: "hi"),
    ])
    let snap = await harness.snapshot()
    let harnessSessionId = await harness.sessionId
    #expect(snap.count == 2)
    #expect(snap.messages[0].content == "sys")
    #expect(snap.messages[1].content == "hi")
    #expect(snap.sessionId == harnessSessionId)
  }

  @Test func appendPersistsBeforeCommit() async throws {
    let tracking = TrackingPersister()
    let harness = try makeHarness(persister: tracking)
    try await harness.applyEdit(.append([ScribeMessage(role: .user, content: "q")]))
    let snap = await harness.snapshot()
    #expect(snap.count == 1)
    #expect(tracking.appendedMessages.count == 1)
    #expect(tracking.appendedMessages[0].content == "q")
  }

  @Test func forkReturnsIdentityChange() async throws {
    let tracking = TrackingPersister()
    let harness = try makeHarness(
      seed: [
        ScribeMessage(role: .system, content: "sys"),
        ScribeMessage(role: .user, content: "hi"),
        ScribeMessage(role: .assistant, content: "hello"),
      ],
      persister: tracking
    )
    let parentId = await harness.sessionId
    let childId = UUID()
    let change = try await harness.applyEdit(.fork(cutAt: 2, newSessionId: childId))
    #expect(change?.previousSessionId == parentId)
    #expect(change?.newSessionId == childId)
    let snap = await harness.snapshot()
    #expect(snap.count == 2)
    #expect(snap.messages[1].content == "hi")
    #expect(tracking.openedSessionCount == 1)
  }

  @Test func submitEmptyIsNoOp() async throws {
    let harness = try makeHarness()
    let outcome = try await harness.submit("   ") { _ in }
    #expect(outcome == .completed)
  }
}

private final class TrackingPersister: SessionPersister, @unchecked Sendable {
  private let lock = Mutex(State())

  private struct State {
    var appended: [ScribeMessage] = []
    var openedSessions: [SessionPersistenceSnapshot] = []
  }

  var appendedMessages: [ScribeMessage] {
    lock.withLock { $0.appended }
  }

  var openedSessionCount: Int {
    lock.withLock { $0.openedSessions.count }
  }

  func append(_ messages: [ScribeMessage]) async throws {
    lock.withLock { $0.appended.append(contentsOf: messages) }
  }

  func directory(for newSessionId: UUID) -> FilePath {
    FilePath("/in-memory/\(newSessionId.uuidString)")
  }

  func openSession(
    _ snapshot: SessionPersistenceSnapshot,
    parent: SessionParent
  ) async throws {
    lock.withLock { $0.openedSessions.append(snapshot) }
  }
}

private extension ScribeConfig {
  static let testValue = ScribeConfig(
    agentModel: "test-model",
    contextWindow: 4000,
    contextWindowThreshold: 0.75,
    serverURL: "https://test.example.com",
    apiKey: "test-token",
    workingDirectory: "/tmp",
    reasoningEnabled: nil
  )
}
