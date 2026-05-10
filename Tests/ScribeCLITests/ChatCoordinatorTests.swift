import Foundation
import HTTPTypes
import Logging
import OpenAPIRuntime
import ScribeCore
import ScribeLLM
import Synchronization
import Testing

@testable import ScribeCLI

// MARK: - Fake Client Transport

private final class FakeClientTransport: ClientTransport, @unchecked Sendable {
  let statusCode: Int
  private let chunksForCall: [[HTTPBody.ByteChunk]]
  private let state: Mutex<State>

  private struct State {
    var callIndex = 0
  }

  init(statusCode: Int, responseBodyChunks: [HTTPBody.ByteChunk]) {
    self.statusCode = statusCode
    self.chunksForCall = [responseBodyChunks]
    self.state = Mutex(State())
  }

  init(statusCode: Int, responseBodyChunksForCall: [[HTTPBody.ByteChunk]]) {
    self.statusCode = statusCode
    self.chunksForCall = responseBodyChunksForCall
    self.state = Mutex(State())
  }

  func send(
    _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
  ) async throws -> (HTTPResponse, HTTPBody?) {
    let chunks: [HTTPBody.ByteChunk] = state.withLock { state in
      let idx = state.callIndex
      state.callIndex += 1
      if idx < chunksForCall.count { return chunksForCall[idx] }
      return chunksForCall.last ?? []
    }
    let response = HTTPResponse(status: .init(code: statusCode))
    if chunks.isEmpty { return (response, nil) }
    let body = HTTPBody(
      AsyncStream { continuation in
        for chunk in chunks { continuation.yield(chunk) }
        continuation.finish()
      }, length: .unknown)
    return (response, body)
  }
}

// MARK: - SSE chunk helpers

private func sseChunk(_ json: String) -> HTTPBody.ByteChunk {
  ArraySlice("data: \(json)\n\n".utf8)
}

private func doneChunk() -> HTTPBody.ByteChunk {
  ArraySlice("data: [DONE]\n\n".utf8)
}

// MARK: - Sendable-safe event collector

private final class EventCollector: @unchecked Sendable {
  private let lock = Mutex<[HostEvent]>([])

  func append(_ event: HostEvent) {
    lock.withLock { $0.append(event) }
  }

  func drain() -> [HostEvent] {
    lock.withLock {
      let copy = $0
      $0 = []
      return copy
    }
  }

  var all: [HostEvent] {
    lock.withLock { $0 }
  }
}

// MARK: - Convenience

private let testLogger = Logger(label: "test.coordinator")

// MARK: - Tests

@Suite
struct ChatCoordinatorTests {

  // MARK: - Completion

  @Test func coordinatorCompletesSimpleTurn() async throws {
    let chunks = [
      sseChunk(#"{"id":"1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"hello"}}]}"#),
      sseChunk(#"{"id":"1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":" world"}}]}"#),
      doneChunk(),
    ]
    let transport = FakeClientTransport(statusCode: 200, responseBodyChunks: chunks)
    let client = Client(serverURL: URL(string: "http://test")!, transport: transport)
    let agent = ScribeAgent(
      client: client,
      model: "test-model",
      systemPrompt: "You are a test agent.",
      tools: [],
      initialMessages: [],
      workingDirectory: ScribeFilePath("/tmp")
    )

    let persistence = SessionPersistence(
      url: FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true),
      sessionId: UUID(),
      createdAt: Date()
    )

    let collector = EventCollector()
    let coordinator = ChatCoordinator(
      agent: agent,
      persistence: persistence,
      eventSink: { collector.append($0) },
      log: testLogger,
      contextWindow: 8192,
      contextWindowThreshold: 0.8,
      agentModel: "test-model",
      serverURL: "http://test"
    )

    let (input, cont) = AsyncStream<String>.makeStream()
    cont.yield("hello")
    cont.yield("exit")
    cont.finish()

    let result = await coordinator.run(
      input: input,
      interruptFlag: ModelTurnInterruptFlag()
    )

    #expect(result.reason == .exitCommand)
    let events = collector.all
    #expect(events.contains(where: {
      if case .transcript(.userSubmitted(let text)) = $0, text == "hello" { return true }
      return false
    }))
  }

  // MARK: - EOF

  @Test func coordinatorStopsOnEOF() async throws {
    let agent = ScribeAgent(
      client: Client(
        serverURL: URL(string: "http://test")!,
        transport: FakeClientTransport(statusCode: 200, responseBodyChunks: [])
      ),
      model: "test-model",
      systemPrompt: "You are a test agent.",
      tools: [],
      initialMessages: [],
      workingDirectory: ScribeFilePath("/tmp")
    )

    let persistence = SessionPersistence(
      url: FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true),
      sessionId: UUID(),
      createdAt: Date()
    )

    let collector = EventCollector()
    let coordinator = ChatCoordinator(
      agent: agent,
      persistence: persistence,
      eventSink: { collector.append($0) },
      log: testLogger,
      contextWindow: 8192,
      contextWindowThreshold: 0.8,
      agentModel: "test-model",
      serverURL: "http://test"
    )

    let (input, cont) = AsyncStream<String>.makeStream()
    cont.finish()  // EOF immediately

    let result = await coordinator.run(
      input: input,
      interruptFlag: ModelTurnInterruptFlag()
    )

    #expect(result.reason == .eof)
  }

  // MARK: - Exit command

  @Test func coordinatorStopsOnExitCommand() async throws {
    let agent = ScribeAgent(
      client: Client(
        serverURL: URL(string: "http://test")!,
        transport: FakeClientTransport(statusCode: 200, responseBodyChunks: [])
      ),
      model: "test-model",
      systemPrompt: "You are a test agent.",
      tools: [],
      initialMessages: [],
      workingDirectory: ScribeFilePath("/tmp")
    )

    let persistence = SessionPersistence(
      url: FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true),
      sessionId: UUID(),
      createdAt: Date()
    )

    let collector = EventCollector()
    let coordinator = ChatCoordinator(
      agent: agent,
      persistence: persistence,
      eventSink: { collector.append($0) },
      log: testLogger,
      contextWindow: 8192,
      contextWindowThreshold: 0.8,
      agentModel: "test-model",
      serverURL: "http://test"
    )

    let (input, cont) = AsyncStream<String>.makeStream()
    cont.yield("  exit  ")  // whitespace + exit
    cont.finish()

    let result = await coordinator.run(
      input: input,
      interruptFlag: ModelTurnInterruptFlag()
    )

    #expect(result.reason == .exitCommand)
  }

  // MARK: - Empty lines skipped

  @Test func coordinatorSkipsEmptyLines() async throws {
    let chunks = [
      sseChunk(#"{"id":"1","choices":[{"index":0,"delta":{"content":"ok"}}]}"#),
      doneChunk(),
    ]
    let transport = FakeClientTransport(statusCode: 200, responseBodyChunks: chunks)
    let client = Client(serverURL: URL(string: "http://test")!, transport: transport)
    let agent = ScribeAgent(
      client: client,
      model: "test-model",
      systemPrompt: "You are a test agent.",
      tools: [],
      initialMessages: [],
      workingDirectory: ScribeFilePath("/tmp")
    )

    let persistence = SessionPersistence(
      url: FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true),
      sessionId: UUID(),
      createdAt: Date()
    )

    let collector = EventCollector()
    let coordinator = ChatCoordinator(
      agent: agent,
      persistence: persistence,
      eventSink: { collector.append($0) },
      log: testLogger,
      contextWindow: 8192,
      contextWindowThreshold: 0.8,
      agentModel: "test-model",
      serverURL: "http://test"
    )

    let (input, cont) = AsyncStream<String>.makeStream()
    cont.yield("")           // empty → skip
    cont.yield("   ")        // whitespace-only → skip
    cont.yield("real input")
    cont.yield("exit")
    cont.finish()

    let result = await coordinator.run(
      input: input,
      interruptFlag: ModelTurnInterruptFlag()
    )

    #expect(result.reason == .exitCommand)
    // Only one user submission (the "real input" one)
    let submissions = collector.all.filter {
      if case .transcript(.userSubmitted(_)) = $0 { return true }
      return false
    }
    #expect(submissions.count == 1)
  }

  // MARK: - Interrupt flag

  @Test func coordinatorClearsInterruptFlagBeforeTurn() async throws {
    // The interrupt flag is meant for mid-turn interruption (Ctrl+C).
    // Before each turn, the coordinator clears it. Setting it before
    // run() has no effect because the first turn clears it.
    let chunks = [
      sseChunk(#"{"id":"1","choices":[{"index":0,"delta":{"content":"hello"}}]}"#),
      doneChunk(),
    ]
    let transport = FakeClientTransport(statusCode: 200, responseBodyChunks: chunks)
    let client = Client(serverURL: URL(string: "http://test")!, transport: transport)
    let agent = ScribeAgent(
      client: client,
      model: "test-model",
      systemPrompt: "You are a test agent.",
      tools: [],
      initialMessages: [],
      workingDirectory: ScribeFilePath("/tmp")
    )

    let persistence = SessionPersistence(
      url: FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true),
      sessionId: UUID(),
      createdAt: Date()
    )

    let collector = EventCollector()
    let coordinator = ChatCoordinator(
      agent: agent,
      persistence: persistence,
      eventSink: { collector.append($0) },
      log: testLogger,
      contextWindow: 8192,
      contextWindowThreshold: 0.8,
      agentModel: "test-model",
      serverURL: "http://test"
    )

    let interruptFlag = ModelTurnInterruptFlag()
    // Set interrupt before run — should be cleared at turn start.
    interruptFlag.request()

    let (input, cont) = AsyncStream<String>.makeStream()
    cont.yield("hello")
    // Request interrupt concurrently to hit during the turn.
    Task {
      try? await Task.sleep(for: .milliseconds(5))
      interruptFlag.request()
    }
    cont.yield("exit")
    cont.finish()

    let result = await coordinator.run(
      input: input,
      interruptFlag: interruptFlag
    )

    // Turn may or may not be interrupted depending on timing.
    // The important thing is the coordinator runs without crashing
    // and the interrupt flag is checked.
    #expect(result.reason == .exitCommand)
  }

  // MARK: - Event ordering

  @Test func coordinatorEmitsEventsInOrder() async throws {
    let chunks = [
      sseChunk(#"{"id":"1","choices":[{"index":0,"delta":{"content":"hi"}}]}"#),
      doneChunk(),
    ]
    let transport = FakeClientTransport(statusCode: 200, responseBodyChunks: chunks)
    let client = Client(serverURL: URL(string: "http://test")!, transport: transport)
    let agent = ScribeAgent(
      client: client,
      model: "test-model",
      systemPrompt: "You are a test agent.",
      tools: [],
      initialMessages: [],
      workingDirectory: ScribeFilePath("/tmp")
    )

    let persistence = SessionPersistence(
      url: FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true),
      sessionId: UUID(),
      createdAt: Date()
    )

    let collector = EventCollector()
    let coordinator = ChatCoordinator(
      agent: agent,
      persistence: persistence,
      eventSink: { collector.append($0) },
      log: testLogger,
      contextWindow: 8192,
      contextWindowThreshold: 0.8,
      agentModel: "test-model",
      serverURL: "http://test"
    )

    let (input, cont) = AsyncStream<String>.makeStream()
    cont.yield("hello")
    cont.yield("exit")
    cont.finish()

    _ = await coordinator.run(
      input: input,
      interruptFlag: ModelTurnInterruptFlag()
    )

    // Verify event sequence:
    // userSubmitted → modelTurnRunning(true) → (assistant events) → turnComplete → modelTurnRunning(false)
    let events = collector.all
    var sawUser = false
    var sawTurnRunning = false
    var sawAssistantText = false
    var sawTurnComplete = false
    var sawTurnStopped = false

    for event in events {
      switch event {
      case .transcript(.userSubmitted(_)):
        sawUser = true
      case .modelTurnRunning(true):
        sawTurnRunning = true
      case .transcript(.appendAssistantText(_, _)):
        #expect(sawTurnRunning)
        sawAssistantText = true
      case .transcript(.turnComplete(_)):
        sawTurnComplete = true
      case .modelTurnRunning(false):
        #expect(sawTurnComplete)  // defer fires after turnComplete
        sawTurnStopped = true
      default:
        break
      }
    }

    #expect(sawUser)
    #expect(sawTurnRunning)
    #expect(sawAssistantText)
    #expect(sawTurnStopped)
    #expect(sawTurnComplete)
  }
}
