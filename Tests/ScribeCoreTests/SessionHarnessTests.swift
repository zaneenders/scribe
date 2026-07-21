import Foundation
import HTTPTypes
import Logging
import OpenAPIRuntime
import ScribeLLM
import Synchronization
import SystemPackage
import Testing

@testable import ScribeCore

@Suite
struct SessionHarnessTests {

  private let logger = Logger(label: "test.session-harness")

  private func makeHarness(
    seed: [ScribeMessage] = [],
    persister: (any SessionPersister)? = nil
  ) throws -> (SessionHarness, SessionMessageQueues) {
    let sessionId = UUID()
    var document = SessionDocument(
      sessionId: sessionId,
      directory: FilePath("/in-memory/\(sessionId.uuidString)"),
      logger: logger
    )
    if !seed.isEmpty {
      document.append(seed)
    }
    let queues = SessionMessageQueues()
    let harness = try SessionHarness(
      configuration: .testValue,
      document: consume document,
      persister: persister ?? InMemorySessionPersister(),
      logger: logger,
      messageQueues: queues
    )
    return (harness, queues)
  }

  @Test func snapshotReflectsDocument() async throws {
    let (harness, _) = try makeHarness(seed: [
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
    let (harness, _) = try makeHarness(persister: tracking)
    try await harness.applyEdit(.append([ScribeMessage(role: .user, content: "q")]))
    let snap = await harness.snapshot()
    #expect(snap.count == 1)
    #expect(tracking.appendedMessages.count == 1)
    #expect(tracking.appendedMessages[0].content == "q")
  }

  @Test func forkReturnsIdentityChange() async throws {
    let tracking = TrackingPersister()
    let (harness, _) = try makeHarness(
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
    let (harness, _) = try makeHarness()
    let outcome = try await harness.submit("   ") { _ in }
    #expect(outcome == .completed)
  }

  @Test func enqueueSteeringWhileBusyIsVisibleToHarness() async throws {
    let (_, queues) = try makeHarness()
    queues.enqueueSteering(text: "steer me")
    #expect(queues.steeringCount() == 1)
    #expect(queues.steeringPreviewTexts() == ["steer me"])
  }

  @Test func followUpQueueDrainsOnlyAfterCompletedTurn() async throws {
    let (_, queues) = try makeHarness()
    queues.enqueueFollowUp(text: "later")
    #expect(queues.followUpCount() == 1)
    queues.clearFollowUp()
    #expect(queues.followUpCount() == 0)
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

    let queues = SessionMessageQueues()
    let harness = SessionHarness(
      configuration: .testValue,
      document: consume document,
      persister: InMemorySessionPersister(),
      agent: agent,
      logger: logger,
      messageQueues: queues
    )
    queues.enqueueSteering(text: "steer-a")
    queues.enqueueSteering(text: "steer-b")

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

    let queues = SessionMessageQueues()
    let harness = SessionHarness(
      configuration: .testValue,
      document: consume document,
      persister: InMemorySessionPersister(),
      agent: agent,
      logger: logger,
      messageQueues: queues
    )
    queues.enqueueSteering(text: "msg-one")
    queues.enqueueSteering(text: "msg-two")
    queues.enqueueSteering(text: "msg-three")
    queues.enqueueSteering(text: "msg-four")

    let first = queues.popSteeringForRecall()
    #expect(first == "msg-one")

    let prompts = Mutex<[String]>([])
    _ = try await harness.submit(
      first!,
      onUserPrompt: { text in prompts.withLock { $0.append(text) } },
      onEvent: { _ in }
    )

    #expect(prompts.withLock { $0 } == ["msg-one", "msg-two", "msg-three", "msg-four"])
    #expect(queues.steeringCount() == 0)
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

    let queues = SessionMessageQueues()
    let harness = SessionHarness(
      configuration: .testValue,
      document: consume document,
      persister: InMemorySessionPersister(),
      agent: agent,
      logger: logger,
      messageQueues: queues
    )
    queues.setSteeringMode(.all)
    queues.enqueueSteering(text: "steer-a")
    queues.enqueueSteering(text: "steer-b")

    _ = try await harness.submit("hello") { _ in }

    #expect(queues.steeringCount() == 0)

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

    let queues = SessionMessageQueues()
    let harness = SessionHarness(
      configuration: .testValue,
      document: consume document,
      persister: InMemorySessionPersister(),
      agent: agent,
      logger: logger,
      messageQueues: queues
    )
    queues.enqueueSteering(text: "steer-a")
    queues.enqueueSteering(text: "steer-b")

    _ = try await harness.submit("hello") { _ in }

    #expect(queues.steeringCount() == 0)

    #expect(transport.callCount == 3)
  }
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

extension ScribeConfig {
  fileprivate static let testValue = ScribeConfig(
    agentModel: "test-model",
    contextWindow: 4000,
    contextWindowThreshold: 0.75,
    serverURL: "https://test.example.com",
    apiKey: "test-token",
    workingDirectory: "/tmp",
    reasoningEnabled: nil
  )
}
