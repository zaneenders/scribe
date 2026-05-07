import Foundation
import HTTPTypes
import Logging
import OpenAPIRuntime
import ScribeCore
import ScribeLLM
import Synchronization
import Testing

// MARK: - Fake Client Transport

/// A test transport that returns canned SSE byte chunks or error responses.
///
/// When `responseBodyChunksForCall` is non-empty, each call to `send` consumes one
/// element from the array, allowing a test to simulate multi-round conversations
/// (e.g. tool-call then text response). After the array is exhausted calls act as
/// if no chunks were provided (empty body).
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
    _ request: HTTPRequest,
    body: HTTPBody?,
    baseURL: URL,
    operationID: String
  ) async throws -> (HTTPResponse, HTTPBody?) {
    let chunks: [HTTPBody.ByteChunk] = state.withLock { state in
      let idx = state.callIndex
      state.callIndex += 1
      if idx < chunksForCall.count {
        return chunksForCall[idx]
      }
      return chunksForCall.last ?? []
    }
    let response = HTTPResponse(status: .init(code: statusCode))
    if chunks.isEmpty {
      return (response, nil)
    }
    let body = HTTPBody(
      AsyncStream { continuation in
        for chunk in chunks {
          continuation.yield(chunk)
        }
        continuation.finish()
      },
      length: .unknown
    )
    return (response, body)
  }
}

// MARK: - Fake tool

private struct FakeTool: ScribeTool {
  static var name: String { "fake_tool" }
  static var description: String { "A fake tool for testing." }
  static var parameters: [ScribeToolParameter] { [] }
  static var promptHint: String? { nil }

  struct Result: Encodable {
    let ok = true
  }

  func run(arguments: String) async throws -> Encodable {
    Result()
  }
}

// MARK: - SSE chunk helpers

private func sseChunk(_ json: String) -> HTTPBody.ByteChunk {
  ArraySlice("data: \(json)\n\n".utf8)
}

private func doneChunk() -> HTTPBody.ByteChunk {
  ArraySlice("data: [DONE]\n\n".utf8)
}

private func errorBody(_ message: String) -> HTTPBody.ByteChunk {
  ArraySlice(#"{"error":{"message":"\#(message)"}}"#.utf8)
}

// MARK: - Test helpers (Sendable-safe)

private final class EventCollector: @unchecked Sendable {
  var events: [TranscriptEvent] = []

  func append(_ event: TranscriptEvent) {
    events.append(event)
  }

  func contains(where predicate: (TranscriptEvent) -> Bool) -> Bool {
    events.contains(where: predicate)
  }
}

/// A Sendable-safe queue of lines for `readUserLine`.
private final class LineSource: @unchecked Sendable {
  private var lines: [String?]

  init(_ lines: [String?]) {
    self.lines = lines
  }

  func next() -> String? {
    if lines.isEmpty { return nil }
    return lines.removeFirst()
  }
}

/// A Sendable-safe bag for `onConversationPersist`.
private final class PersistCollector: @unchecked Sendable {
  var history: [[Components.Schemas.ChatMessage]] = []

  func append(_ messages: [Components.Schemas.ChatMessage]) {
    history.append(messages)
  }
}

// MARK: - Convenience

private let testLogger = Logger(label: "test")

private func makeAgent(
  statusCode: Int = 200,
  chunks: [HTTPBody.ByteChunk],
  model: String = "test-model",
  tools: [any ScribeTool] = []
) -> ScribeAgent {
  let transport = FakeClientTransport(statusCode: statusCode, responseBodyChunks: chunks)
  let client = Client(serverURL: URL(string: "http://test")!, transport: transport)
  let config = AgentConfig(agentModel: model, serverURL: "http://test")
  return ScribeAgent(
    configuration: config,
    client: client,
    systemPrompt: "You are a test assistant.",
    tools: tools
  )
}

/// Variant that supplies a sequence of per-call chunk arrays, so each
/// simulated API call consumes the next entry (tool call → text reply, etc.).
private func makeAgent(
  statusCode: Int = 200,
  chunksForCall: [[HTTPBody.ByteChunk]],
  model: String = "test-model",
  tools: [any ScribeTool] = []
) -> ScribeAgent {
  let transport = FakeClientTransport(statusCode: statusCode, responseBodyChunksForCall: chunksForCall)
  let client = Client(serverURL: URL(string: "http://test")!, transport: transport)
  let config = AgentConfig(agentModel: model, serverURL: "http://test")
  return ScribeAgent(
    configuration: config,
    client: client,
    systemPrompt: "You are a test assistant.",
    tools: tools
  )
}

// MARK: - Tests

@Suite
struct ScribeAgentTests {

  // MARK: - init

  @Test func initStoresConfiguration() {
    let agent = makeAgent(chunks: [doneChunk()])
    #expect(agent.configuration.agentModel == "test-model")
    #expect(agent.systemPrompt == "You are a test assistant.")
  }

  @Test func initStoresClient() {
    let agent = makeAgent(chunks: [doneChunk()])
    // Agent stores the client provided at init
    #expect(type(of: agent.client) == Client.self)
  }

  // MARK: - streamTurn: outcome

  @Test func streamTurnCompletesWithAnswerText() async throws {
    let chunks = [
      sseChunk(
        #"{"id":"1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"done"}}]}"#
      ),
      doneChunk(),
    ]
    let agent = makeAgent(chunks: chunks)

    let messages: [Components.Schemas.ChatMessage] = []
    let ts = agent.streamTurn(messages: messages, log: testLogger)
    // Drain events
    Task { for await _ in ts.events { } }
    let result = try await ts.result.value
    #expect(result.outcome == .completed)
  }

  @Test func streamTurnPassesMaxToolRounds() async throws {
    // Return a tool call that would loop forever, but maxToolRounds=1 stops it.
    let chunks = [
      sseChunk(
        #"{"id":"1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"fake_tool","arguments":"{}"}}]}}]}"#
      ),
      doneChunk(),
    ]
    let agent = makeAgent(chunks: chunks, tools: [FakeTool()])

    let messages: [Components.Schemas.ChatMessage] = []
    let ts = agent.streamTurn(messages: messages, log: testLogger, maxToolRounds: 1)
    Task { for await _ in ts.events { } }
    let result = try await ts.result.value
    #expect(result.outcome == .toolRoundLimit(rounds: 1))
  }

  // MARK: - streamTurn: events

  @Test func streamTurnYieldsAssistantTextEvents() async throws {
    let chunks = [
      sseChunk(
        #"{"id":"1","choices":[{"index":0,"delta":{"content":"hello"}}]}"#
      ),
      sseChunk(
        #"{"id":"1","choices":[{"index":0,"delta":{"content":" world"}}]}"#
      ),
      doneChunk(),
    ]
    let agent = makeAgent(chunks: chunks)

    let ts = agent.streamTurn(messages: [], log: testLogger)
    var texts: [String] = []
    for await event in ts.events {
      if case .appendAssistantText(_, let text) = event {
        texts.append(text)
      }
    }
    let result = try await ts.result.value

    #expect(texts == ["hello", " world"])
    #expect(result.outcome == .completed)
  }

  @Test func streamTurnYieldsToolInvocationEvents() async throws {
    let toolChunks = [
      sseChunk(
        #"{"id":"1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"fake_tool","arguments":"{}"}}]}}]}"#
      ),
      doneChunk(),
    ]
    let replyChunks = [
      sseChunk(
        #"{"id":"2","choices":[{"index":0,"delta":{"content":"done"}}]}"#
      ),
      doneChunk(),
    ]
    let agent = makeAgent(chunksForCall: [toolChunks, replyChunks], tools: [FakeTool()])

    let ts = agent.streamTurn(messages: [], log: testLogger)
    let collector = EventCollector()
    for await event in ts.events {
      collector.append(event)
    }
    let result = try await ts.result.value

    #expect(result.outcome == .completed)

    // Should have tool round header, tool invocation, and blank line
    let hasHeader = collector.contains(where: {
      if case .toolRoundHeader(let round, let names) = $0,
        round == 1, names == ["fake_tool"] { return true }
      return false
    })
    #expect(hasHeader)

    let hasToolInvocation = collector.contains(where: {
      if case .toolInvocation(let name, _, _) = $0, name == "fake_tool" { return true }
      return false
    })
    #expect(hasToolInvocation)
  }

  @Test func streamTurnYieldsUsageEvent() async throws {
    let chunks = [
      sseChunk(
        #"{"id":"1","choices":[{"index":0,"delta":{"content":"x"}}]}"#
      ),
      sseChunk(
        #"{"id":"1","choices":[],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}"#
      ),
      doneChunk(),
    ]
    let agent = makeAgent(chunks: chunks)

    let ts = agent.streamTurn(messages: [], log: testLogger)
    let collector = EventCollector()
    for await event in ts.events {
      collector.append(event)
    }
    _ = try await ts.result.value

    let hasUsage = collector.contains(where: {
      if case .usage(let u, _) = $0,
        u.promptTokens == 10, u.completionTokens == 5, u.totalTokens == 15 { return true }
      return false
    })
    #expect(hasUsage)
  }

  // MARK: - streamTurn: result.messages

  @Test func streamTurnResultMessagesContainsAssistantMessage() async throws {
    let chunks = [
      sseChunk(
        #"{"id":"1","choices":[{"index":0,"delta":{"content":"reply"}}]}"#
      ),
      doneChunk(),
    ]
    let agent = makeAgent(chunks: chunks)

    let messages: [Components.Schemas.ChatMessage] = [
      .init(role: .user, content: "hello")
    ]
    let ts = agent.streamTurn(messages: messages, log: testLogger)
    Task { for await _ in ts.events { } }
    let result = try await ts.result.value

    #expect(result.messages.count == 2)  // user + assistant
    #expect(result.messages[0].role == .user)
    #expect(result.messages[0].content == "hello")
    #expect(result.messages[1].role == .assistant)
    #expect(result.messages[1].content == "reply")
  }

  @Test func streamTurnResultMessagesAfterToolRound() async throws {
    let toolChunks = [
      sseChunk(
        #"{"id":"1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"fake_tool","arguments":"{}"}}]}}]}"#
      ),
      doneChunk(),
    ]
    let replyChunks = [
      sseChunk(
        #"{"id":"2","choices":[{"index":0,"delta":{"content":"done"}}]}"#
      ),
      doneChunk(),
    ]
    let agent = makeAgent(chunksForCall: [toolChunks, replyChunks], tools: [FakeTool()])

    let ts = agent.streamTurn(messages: [], log: testLogger)
    Task { for await _ in ts.events { } }
    let result = try await ts.result.value

    #expect(result.outcome == .completed)
    #expect(result.messages.count == 3)  // assistant + tool + assistant
    #expect(result.messages[0].role == .assistant)
    #expect(result.messages[1].role == .tool)
    #expect(result.messages[1].toolCallId == "c1")
    #expect(result.messages[2].role == .assistant)
    #expect(result.messages[2].content == "done")
  }

  // MARK: - streamTurn: error propagation

  @Test func streamTurnPropagatesHTTPError() async {
    let agent = makeAgent(statusCode: 500, chunks: [errorBody("boom")])
    let ts = agent.streamTurn(messages: [], log: testLogger)
    Task { for await _ in ts.events { } }

    do {
      _ = try await ts.result.value
      #expect(Bool(false), "expected error")
    } catch let error as ScribeError {
      guard case .apiHTTPError(let code, _, _) = error else {
        #expect(Bool(false))
        return
      }
      #expect(code == 500)
    } catch {
      #expect(Bool(false))
    }
  }

  @Test func streamTurnStreamFinishesOnError() async {
    let agent = makeAgent(statusCode: 500, chunks: [errorBody("boom")])
    let ts = agent.streamTurn(messages: [], log: testLogger)

    var eventCount = 0
    for await _ in ts.events {
      eventCount += 1
    }

    // Stream should finish (defer in Task body) even though result throws
    let didThrow: Bool
    do {
      _ = try await ts.result.value
      didThrow = false
    } catch {
      didThrow = true
    }
    #expect(didThrow)
    // Stream finishes cleanly (no events from harness because HTTP call throws
    // before any SSE chunks are processed)
    #expect(eventCount == 0)
  }

  // MARK: - streamTurn: shouldAbortTurn

  @Test func streamTurnAbortReturnsInterrupted() async throws {
    let chunks = [
      sseChunk(
        #"{"id":"1","choices":[{"index":0,"delta":{"content":"hello"}}]}"#
      ),
      doneChunk(),
    ]
    let agent = makeAgent(chunks: chunks)

    // Abort before HTTP request — the first shouldAbortTurn call happens
    // before the harness round starts.
    let ts = agent.streamTurn(
      messages: [],
      log: testLogger,
      shouldAbortTurn: { true }
    )
    Task { for await _ in ts.events { } }
    let result = try await ts.result.value
    #expect(result.outcome == .interrupted)
  }

  // MARK: - runIPC

  @Test func runIPCSuccessReturnsAssistantText() async {
    let chunks = [
      sseChunk(
        #"{"id":"1","choices":[{"index":0,"delta":{"content":"Hello from agent"}}]}"#
      ),
      doneChunk(),
    ]
    let agent = makeAgent(chunks: chunks)

    let request = ScribeAgentRequest(message: "say hello")
    let response = await agent.runIPC(request: request, onEvent: { _ in }, log: testLogger)

    #expect(response.ok == true)
    #expect(response.assistant == "Hello from agent")
    #expect(response.error == nil)
  }

  @Test func runIPCWithToolSucceeds() async {
    // First call: tool request.  Second call: text reply.
    let toolCallChunks = [
      sseChunk(
        #"{"id":"1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"fake_tool","arguments":"{}"}}]}}]}"#
      ),
      doneChunk(),
    ]
    let textReplyChunks = [
      sseChunk(
        #"{"id":"2","choices":[{"index":0,"delta":{"content":"Used tool successfully"}}]}"#
      ),
      doneChunk(),
    ]
    let agent = makeAgent(
      chunksForCall: [toolCallChunks, textReplyChunks],
      tools: [FakeTool()]
    )

    let request = ScribeAgentRequest(message: "use tool")
    let response = await agent.runIPC(request: request, onEvent: { _ in }, log: testLogger)

    #expect(response.ok == true)
    #expect(response.assistant == "Used tool successfully")
  }

  @Test func runIPCEmptyResponseHandled() async {
    let agent = makeAgent(chunks: [doneChunk()])

    let request = ScribeAgentRequest(message: "anything")
    let response = await agent.runIPC(request: request, onEvent: { _ in }, log: testLogger)

    #expect(response.ok == true)
    #expect(response.assistant == "")
  }

  @Test func runIPCErrorReturnsFailure() async {
    // runIPC doesn't expose shouldAbortTurn, but we can test the error path.
    let request = ScribeAgentRequest(message: "hi")
    let errorAgent = makeAgent(statusCode: 500, chunks: [errorBody("fail")])
    let response = await errorAgent.runIPC(
      request: request, onEvent: { _ in }, log: testLogger)

    #expect(response.ok == false)
    #expect(response.error?.isEmpty == false)
  }

  @Test func runIPCErrorReturnsFailureWithDescription() async {
    let agent = makeAgent(statusCode: 400, chunks: [errorBody("bad request")])
    let request = ScribeAgentRequest(message: "hi")
    let response = await agent.runIPC(request: request, onEvent: { _ in }, log: testLogger)

    #expect(response.ok == false)
    #expect(response.error?.contains("400") == true)
  }

  // MARK: - runInteractive

  @Test func runInteractiveSingleTurnCompletes() async throws {
    let chunks = [
      sseChunk(
        #"{"id":"1","choices":[{"index":0,"delta":{"content":"hello"}}]}"#
      ),
      doneChunk(),
    ]
    let agent = makeAgent(chunks: chunks)
    let collector = EventCollector()
    let lines = LineSource(["hello", nil])

    try await agent.runInteractive(
      onEvent: { collector.append($0) },
      readUserLine: { lines.next() },
      log: testLogger
    )

    let hasTurnStart = collector.contains(where: {
      if case .modelTurnRunning(let running) = $0, running { return true }
      return false
    })
    #expect(hasTurnStart)

    let hasTurnEnd = collector.contains(where: {
      if case .modelTurnRunning(let running) = $0, !running { return true }
      return false
    })
    #expect(hasTurnEnd)

    let hasText = collector.contains(where: {
      if case .appendAssistantText(_, let text) = $0, text == "hello" { return true }
      return false
    })
    #expect(hasText)
  }

  @Test func runInteractiveMultipleTurnsAccumulateHistory() async throws {
    let turn1Chunks = [
      sseChunk(
        #"{"id":"1","choices":[{"index":0,"delta":{"content":"reply1"}}]}"#
      ),
      doneChunk(),
    ]
    let turn2Chunks = [
      sseChunk(
        #"{"id":"2","choices":[{"index":0,"delta":{"content":"reply2"}}]}"#
      ),
      doneChunk(),
    ]
    let agent = makeAgent(chunksForCall: [turn1Chunks, turn2Chunks])

    let lines = LineSource(["msg1", "msg2", nil])
    let persisted = PersistCollector()
    try await agent.runInteractive(
      onEvent: { _ in },
      readUserLine: { lines.next() },
      onConversationPersist: { persisted.append($0) },
      log: testLogger
    )

    #expect(persisted.history.count >= 2)
    let final = persisted.history.last!
    #expect(final.count == 5)
    #expect(final[0].role == .system)
    #expect(final[1].role == .user)
    #expect(final[1].content == "msg1")
    #expect(final[2].role == .assistant)
    #expect(final[2].content == "reply1")
    #expect(final[3].role == .user)
    #expect(final[3].content == "msg2")
    #expect(final[4].role == .assistant)
    #expect(final[4].content == "reply2")
  }

  @Test func runInteractiveExitCommandExits() async throws {
    let agent = makeAgent(chunks: [doneChunk()])
    let collector = EventCollector()
    let lines = LineSource(["exit", "should not be read"])

    try await agent.runInteractive(
      onEvent: { collector.append($0) },
      readUserLine: { lines.next() },
      log: testLogger
    )

    let hasTurnEvent = collector.contains(where: {
      if case .modelTurnRunning = $0 { return true }
      return false
    })
    #expect(!hasTurnEvent)
  }

  @Test func runInteractiveEmptyLinesAreSkipped() async throws {
    let chunks = [
      sseChunk(
        #"{"id":"1","choices":[{"index":0,"delta":{"content":"reply"}}]}"#
      ),
      doneChunk(),
    ]
    let agent = makeAgent(chunks: chunks)
    let lines = LineSource(["", "  ", "real message", nil])

    try await agent.runInteractive(
      onEvent: { _ in },
      readUserLine: { lines.next() },
      log: testLogger
    )
    // No throw means empty lines were skipped and real message triggered a turn
  }

  @Test func runInteractiveEOFExits() async throws {
    let agent = makeAgent(chunks: [doneChunk()])
    let collector = EventCollector()

    try await agent.runInteractive(
      onEvent: { collector.append($0) },
      readUserLine: { nil },
      log: testLogger
    )

    let hasTurnEvent = collector.contains(where: {
      if case .modelTurnRunning = $0 { return true }
      return false
    })
    #expect(!hasTurnEvent)
  }

  @Test func runInteractiveInitialConversationNonSystemThrows() async {
    let agent = makeAgent(chunks: [doneChunk()])

    let badInitial: [Components.Schemas.ChatMessage] = [
      .init(role: .user, content: "bad start")
    ]

    do {
      try await agent.runInteractive(
        onEvent: { _ in },
        readUserLine: { nil },
        initialConversation: badInitial,
        log: testLogger
      )
      #expect(Bool(false), "expected error")
    } catch let error as ScribeError {
      guard case .sessionCorrupted = error else {
        #expect(Bool(false))
        return
      }
    } catch {
      #expect(Bool(false))
    }
  }

  @Test func runInteractiveInitialConversationResumes() async throws {
    let chunks = [
      sseChunk(
        #"{"id":"1","choices":[{"index":0,"delta":{"content":"new reply"}}]}"#
      ),
      doneChunk(),
    ]
    let agent = makeAgent(chunks: chunks)

    let initial: [Components.Schemas.ChatMessage] = [
      .init(role: .system, content: "You are helpful."),
      .init(role: .user, content: "previous"),
      .init(role: .assistant, content: "old reply"),
    ]

    let lines = LineSource(["new message", nil])
    try await agent.runInteractive(
      onEvent: { _ in },
      readUserLine: { lines.next() },
      initialConversation: initial,
      log: testLogger
    )
  }

  @Test func runInteractiveErrorInTurnEmitsHarnessError() async throws {
    let agent = makeAgent(statusCode: 500, chunks: [errorBody("fail")])
    let collector = EventCollector()
    let lines = LineSource(["trigger error", nil])

    try await agent.runInteractive(
      onEvent: { collector.append($0) },
      readUserLine: { lines.next() },
      log: testLogger
    )

    let hasError = collector.contains(where: {
      if case .harnessError = $0 { return true }
      return false
    })
    #expect(hasError)
  }

  @Test func runInteractiveInterruptedTurnEmitsEvent() async throws {
    let agent = makeAgent(chunks: [doneChunk()])
    let collector = EventCollector()
    let lines = LineSource(["msg", nil])

    try await agent.runInteractive(
      onEvent: { collector.append($0) },
      readUserLine: { lines.next() },
      shouldAbortTurn: { true },
      log: testLogger
    )

    let hasInterrupted = collector.contains(where: {
      if case .turnInterrupted = $0 { return true }
      return false
    })
    #expect(hasInterrupted)
  }

  @Test func runInteractivePrepareModelTurnStartIsCalled() async throws {
    let chunks = [
      sseChunk(
        #"{"id":"1","choices":[{"index":0,"delta":{"content":"ok"}}]}"#
      ),
      doneChunk(),
    ]
    let agent = makeAgent(chunks: chunks)

    let called = Mutex(false)
    let lines = LineSource(["msg", nil])
    try await agent.runInteractive(
      onEvent: { _ in },
      readUserLine: { lines.next() },
      prepareModelTurnStart: { called.withLock { $0 = true } },
      log: testLogger
    )

    #expect(called.withLock { $0 })
  }

  // MARK: - runInteractive: error recovery

  @Test func runInteractiveErrorRemovesLastUserMessage() async throws {
    let agent = makeAgent(statusCode: 500, chunks: [errorBody("fail")])

    let lines = LineSource(["bad message", nil])
    let persisted = PersistCollector()
    try await agent.runInteractive(
      onEvent: { _ in },
      readUserLine: { lines.next() },
      onConversationPersist: { persisted.append($0) },
      log: testLogger
    )

    let final = persisted.history.last!
    let userMessages = final.filter { $0.role == .user }
    #expect(userMessages.isEmpty)
  }
}
