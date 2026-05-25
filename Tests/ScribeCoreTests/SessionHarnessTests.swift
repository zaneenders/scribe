import Foundation
import HTTPTypes
import Logging
import OpenAPIRuntime
@testable import ScribeCore
import ScribeLLM
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

  @Test func enqueueSteeringWhileBusyIsVisibleToHarness() async throws {
    let harness = try makeHarness()
    harness.enqueueSteering("steer me")
    #expect(harness.steeringQueueCount == 1)
    #expect(harness.steeringQueuePreview() == ["steer me"])
  }

  @Test func followUpQueueDrainsOnlyAfterCompletedTurn() async throws {
    let harness = try makeHarness()
    harness.enqueueFollowUp("later")
    #expect(harness.followUpQueueCount == 1)
    await harness.clearFollowUpQueue()
    #expect(harness.followUpQueueCount == 0)
  }

  @Test func steeringDrainInvokesOnUserPromptForEachMessage() async throws {
    let reply = #"{"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}"#
    let chunks = [sseChunk(reply), doneChunk()]
    let transport = CountingTransport(chunks: chunks)
    let client = Client(serverURL: URL(string: "http://test")!, transport: transport)
    let agent = ScribeAgent(
      client: client,
      model: "test-model",
      workingDirectory: FilePath("/tmp"),
      reasoningEnabled: nil,
      logger: logger
    )

    let sessionId = UUID()
    var document = SessionDocument(
      sessionId: sessionId,
      directory: FilePath("/in-memory/\(sessionId.uuidString)"),
      logger: logger
    )
    document.append([ScribeMessage(role: .system, content: "sys")])

    let harness = SessionHarness(
      configuration: .testValue,
      document: consume document,
      persister: InMemorySessionPersister(),
      agent: agent,
      logger: logger
    )
    harness.enqueueSteering("steer-a")
    harness.enqueueSteering("steer-b")

    let prompts = Mutex<[String]>([])
    _ = try await harness.submit(
      "hello",
      onUserPrompt: { text in prompts.withLock { $0.append(text) } },
      onEvent: { _ in }
    )

    #expect(prompts.withLock { $0 } == ["hello", "steer-a", "steer-b"])
  }

  @Test func fourQueuedMessagesAllRunAfterPopAndSubmit() async throws {
    let reply = #"{"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}"#
    let chunks = [sseChunk(reply), doneChunk()]
    let transport = CountingTransport(chunks: chunks)
    let client = Client(serverURL: URL(string: "http://test")!, transport: transport)
    let agent = ScribeAgent(
      client: client,
      model: "test-model",
      workingDirectory: FilePath("/tmp"),
      reasoningEnabled: nil,
      logger: logger
    )

    let sessionId = UUID()
    var document = SessionDocument(
      sessionId: sessionId,
      directory: FilePath("/in-memory/\(sessionId.uuidString)"),
      logger: logger
    )
    document.append([ScribeMessage(role: .system, content: "sys")])

    let harness = SessionHarness(
      configuration: .testValue,
      document: consume document,
      persister: InMemorySessionPersister(),
      agent: agent,
      logger: logger
    )
    harness.enqueueSteering("msg-one")
    harness.enqueueSteering("msg-two")
    harness.enqueueSteering("msg-three")
    harness.enqueueSteering("msg-four")

    let first = harness.popSteeringForRecall()
    #expect(first == "msg-one")

    let prompts = Mutex<[String]>([])
    _ = try await harness.submit(
      first!,
      onUserPrompt: { text in prompts.withLock { $0.append(text) } },
      onEvent: { _ in }
    )

    #expect(prompts.withLock { $0 } == ["msg-one", "msg-two", "msg-three", "msg-four"])
    #expect(harness.steeringQueueCount == 0)
    #expect(transport.callCount == 4)
  }

  @Test func steeringModeAllDrainsInSingleTurn() async throws {
    let reply = #"{"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}"#
    let chunks = [sseChunk(reply), doneChunk()]
    let transport = CountingTransport(chunks: chunks)
    let client = Client(serverURL: URL(string: "http://test")!, transport: transport)
    let agent = ScribeAgent(
      client: client,
      model: "test-model",
      workingDirectory: FilePath("/tmp"),
      reasoningEnabled: nil,
      logger: logger
    )

    let sessionId = UUID()
    var document = SessionDocument(
      sessionId: sessionId,
      directory: FilePath("/in-memory/\(sessionId.uuidString)"),
      logger: logger
    )
    document.append([ScribeMessage(role: .system, content: "sys")])

    let harness = SessionHarness(
      configuration: .testValue,
      document: consume document,
      persister: InMemorySessionPersister(),
      agent: agent,
      logger: logger
    )
    await harness.setSteeringMode(.all)
    harness.enqueueSteering("steer-a")
    harness.enqueueSteering("steer-b")

    _ = try await harness.submit("hello") { _ in }

    #expect(harness.steeringQueueCount == 0)
    // Initial turn + one steering turn (both steer messages batched).
    #expect(transport.callCount == 2)

    let snap = await harness.snapshot()
    let userContents = snap.messages.filter { $0.role == .user }.map(\.content)
    #expect(userContents.contains("hello"))
    #expect(userContents.contains("steer-a"))
    #expect(userContents.contains("steer-b"))
  }

  @Test func steeringModeOneAtATimeDrainsSequentially() async throws {
    let reply = #"{"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}"#
    let chunks = [sseChunk(reply), doneChunk()]
    let transport = CountingTransport(chunks: chunks)
    let client = Client(serverURL: URL(string: "http://test")!, transport: transport)
    let agent = ScribeAgent(
      client: client,
      model: "test-model",
      workingDirectory: FilePath("/tmp"),
      reasoningEnabled: nil,
      logger: logger
    )

    let sessionId = UUID()
    var document = SessionDocument(
      sessionId: sessionId,
      directory: FilePath("/in-memory/\(sessionId.uuidString)"),
      logger: logger
    )
    document.append([ScribeMessage(role: .system, content: "sys")])

    let harness = SessionHarness(
      configuration: .testValue,
      document: consume document,
      persister: InMemorySessionPersister(),
      agent: agent,
      logger: logger
    )
    harness.enqueueSteering("steer-a")
    harness.enqueueSteering("steer-b")

    _ = try await harness.submit("hello") { _ in }

    #expect(harness.steeringQueueCount == 0)
    // Initial + two steering turns (one message each).
    #expect(transport.callCount == 3)
  }
}

private func sseChunk(_ json: String) -> HTTPBody.ByteChunk {
  ArraySlice("data: \(json)\n\n".utf8)
}

private func doneChunk() -> HTTPBody.ByteChunk {
  ArraySlice("data: [DONE]\n\n".utf8)
}

private final class CountingTransport: ClientTransport, Sendable {
  private let chunks: [HTTPBody.ByteChunk]
  private let state = Mutex(0)

  var callCount: Int { state.withLock { $0 } }

  init(chunks: [HTTPBody.ByteChunk]) {
    self.chunks = chunks
  }

  func send(
    _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
  ) async throws -> (HTTPResponse, HTTPBody?) {
    state.withLock { $0 += 1 }
    let response = HTTPResponse(status: .init(code: 200))
    let streamBody = HTTPBody(
      AsyncStream { continuation in
        for chunk in chunks { continuation.yield(chunk) }
        continuation.finish()
      },
      length: .unknown)
    return (response, streamBody)
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
