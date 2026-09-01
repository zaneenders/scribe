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
  ) throws -> (SessionHarness, SessionMessageQueue) {
    let sessionId = UUID()
    var document = SessionDocument(
      sessionId: sessionId,
      directory: FilePath("/in-memory/\(sessionId.uuidString)"),
      logger: logger
    )
    if !seed.isEmpty {
      document.append(seed)
    }
    let queue = SessionMessageQueue()
    let harness = try SessionHarness(
      configuration: .testValue,
      document: consume document,
      persister: persister ?? InMemorySessionPersister(),
      logger: logger,
      messageQueue: queue
    )
    return (harness, queue)
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

  @Test func enqueueWhileBusyIsVisibleToHarness() async throws {
    let (_, queue) = try makeHarness()
    queue.enqueue(text: "steer me")
    #expect(queue.count() == 1)
    #expect(queue.previewTexts() == ["steer me"])
  }

  @Test func queueDrainInvokesOnUserPromptForEachMessage() async throws {
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

    let queue = SessionMessageQueue()
    let harness = SessionHarness(
      configuration: .testValue,
      document: consume document,
      persister: InMemorySessionPersister(),
      agent: agent,
      logger: logger,
      messageQueue: queue
    )
    queue.enqueue(text: "steer-a")
    queue.enqueue(text: "steer-b")

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

    let queue = SessionMessageQueue()
    let harness = SessionHarness(
      configuration: .testValue,
      document: consume document,
      persister: InMemorySessionPersister(),
      agent: agent,
      logger: logger,
      messageQueue: queue
    )
    queue.enqueue(text: "msg-one")
    queue.enqueue(text: "msg-two")
    queue.enqueue(text: "msg-three")
    queue.enqueue(text: "msg-four")

    let first = queue.popForRecall()
    #expect(first == "msg-one")

    let prompts = Mutex<[String]>([])
    _ = try await harness.submit(
      first!,
      onUserPrompt: { text in prompts.withLock { $0.append(text) } },
      onEvent: { _ in }
    )

    #expect(prompts.withLock { $0 } == ["msg-one", "msg-two", "msg-three", "msg-four"])
    #expect(queue.count() == 0)
    #expect(transport.callCount == 4)
  }

  @Test func modeAllDrainsInSingleTurn() async throws {
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

    let queue = SessionMessageQueue()
    let harness = SessionHarness(
      configuration: .testValue,
      document: consume document,
      persister: InMemorySessionPersister(),
      agent: agent,
      logger: logger,
      messageQueue: queue
    )
    queue.setMode(.all)
    queue.enqueue(text: "steer-a")
    queue.enqueue(text: "steer-b")

    _ = try await harness.submit("hello") { _ in }

    #expect(queue.count() == 0)

    #expect(transport.callCount == 2)

    let snap = await harness.snapshot()
    let userContents = snap.messages.filter { $0.role == .user }.map(\.content)
    #expect(userContents.contains("hello"))
    #expect(userContents.contains("steer-a"))
    #expect(userContents.contains("steer-b"))
  }

  @Test func modeOneAtATimeDrainsSequentially() async throws {
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

    let queue = SessionMessageQueue()
    let harness = SessionHarness(
      configuration: .testValue,
      document: consume document,
      persister: InMemorySessionPersister(),
      agent: agent,
      logger: logger,
      messageQueue: queue
    )
    queue.enqueue(text: "steer-a")
    queue.enqueue(text: "steer-b")

    _ = try await harness.submit("hello") { _ in }

    #expect(queue.count() == 0)

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
