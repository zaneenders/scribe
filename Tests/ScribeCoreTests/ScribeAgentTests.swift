import Foundation
import HTTPTypes
import Logging
import OpenAPIRuntime
import ScribeCore
import ScribeLLM
import Synchronization
import Testing

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

// MARK: - Fake tool

private struct FakeTool: ScribeTool {
  static var name: String { "fake_tool" }
  static var description: String { "A fake tool for testing." }
  static var parameters: [ScribeToolParameter] { [] }
  static var promptHint: String? { nil }
  struct Result: Encodable { let ok = true }
  func run(arguments: String) async throws -> Encodable { Result() }
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
  let chatTools = tools.map { type(of: $0).toChatTool() }
  let harness = AgentHarness(client: client, model: model, tools: chatTools)
  return ScribeAgent(harness: harness, registry: ToolRegistry(tools: tools))
}

private func makeAgent(
  statusCode: Int = 200,
  chunksForCall: [[HTTPBody.ByteChunk]],
  model: String = "test-model",
  tools: [any ScribeTool] = []
) -> ScribeAgent {
  let transport = FakeClientTransport(
    statusCode: statusCode, responseBodyChunksForCall: chunksForCall)
  let client = Client(serverURL: URL(string: "http://test")!, transport: transport)
  let chatTools = tools.map { type(of: $0).toChatTool() }
  let harness = AgentHarness(client: client, model: model, tools: chatTools)
  return ScribeAgent(harness: harness, registry: ToolRegistry(tools: tools))
}

// MARK: - Tests

@Suite
struct ScribeAgentTests {

  // MARK: - streamTurn: outcome

  @Test func streamTurnCompletesWithAnswerText() async throws {
    let chunks = [
      sseChunk(#"{"id":"1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"done"}}]}"#),
      doneChunk(),
    ]
    let agent = makeAgent(chunks: chunks)
    let ts = agent.streamTurn(messages: [], log: testLogger)
    Task { for await _ in ts.events { } }
    let result = try await ts.result.value
    #expect(result.outcome == .completed)
  }

  @Test func streamTurnPassesMaxToolRounds() async throws {
    let chunks = [
      sseChunk(#"{"id":"1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"fake_tool","arguments":"{}"}}]}}]}"#),
      doneChunk(),
    ]
    let agent = makeAgent(chunks: chunks, tools: [FakeTool()])
    let ts = agent.streamTurn(messages: [], log: testLogger, maxToolRounds: 1)
    Task { for await _ in ts.events { } }
    let result = try await ts.result.value
    #expect(result.outcome == .toolRoundLimit(rounds: 1))
  }

  // MARK: - streamTurn: events

  @Test func streamTurnYieldsAssistantTextEvents() async throws {
    let chunks = [
      sseChunk(#"{"id":"1","choices":[{"index":0,"delta":{"content":"hello"}}]}"#),
      sseChunk(#"{"id":"1","choices":[{"index":0,"delta":{"content":" world"}}]}"#),
      doneChunk(),
    ]
    let agent = makeAgent(chunks: chunks)
    let ts = agent.streamTurn(messages: [], log: testLogger)
    var texts: [String] = []
    for await event in ts.events {
      if case .appendAssistantText(_, let text) = event { texts.append(text) }
    }
    let result = try await ts.result.value
    #expect(texts == ["hello", " world"])
    #expect(result.outcome == .completed)
  }

  @Test func streamTurnYieldsToolInvocationEvents() async throws {
    let toolChunks = [
      sseChunk(#"{"id":"1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"fake_tool","arguments":"{}"}}]}}]}"#),
      doneChunk(),
    ]
    let replyChunks = [
      sseChunk(#"{"id":"2","choices":[{"index":0,"delta":{"content":"done"}}]}"#),
      doneChunk(),
    ]
    let agent = makeAgent(chunksForCall: [toolChunks, replyChunks], tools: [FakeTool()])
    let ts = agent.streamTurn(messages: [], log: testLogger)
    var events: [TranscriptEvent] = []
    for await event in ts.events { events.append(event) }
    let result = try await ts.result.value
    #expect(result.outcome == .completed)
    let hasHeader = events.contains(where: {
      if case .toolRoundHeader(let r, let names) = $0, r == 1, names == ["fake_tool"] { return true }
      return false
    })
    #expect(hasHeader)
    let hasInvocation = events.contains(where: {
      if case .toolInvocation(let name, _, _) = $0, name == "fake_tool" { return true }
      return false
    })
    #expect(hasInvocation)
  }

  @Test func streamTurnYieldsUsageEvent() async throws {
    let chunks = [
      sseChunk(#"{"id":"1","choices":[{"index":0,"delta":{"content":"x"}}]}"#),
      sseChunk(#"{"id":"1","choices":[],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}"#),
      doneChunk(),
    ]
    let agent = makeAgent(chunks: chunks)
    let ts = agent.streamTurn(messages: [], log: testLogger)
    var events: [TranscriptEvent] = []
    for await event in ts.events { events.append(event) }
    _ = try await ts.result.value
    let hasUsage = events.contains(where: {
      if case .usage(let u, _) = $0, u.promptTokens == 10, u.completionTokens == 5, u.totalTokens == 15 { return true }
      return false
    })
    #expect(hasUsage)
  }

  // MARK: - streamTurn: result.messages

  @Test func streamTurnResultMessagesContainsAssistantMessage() async throws {
    let chunks = [
      sseChunk(#"{"id":"1","choices":[{"index":0,"delta":{"content":"reply"}}]}"#),
      doneChunk(),
    ]
    let agent = makeAgent(chunks: chunks)
    let messages: [Components.Schemas.ChatMessage] = [.init(role: .user, content: "hello")]
    let ts = agent.streamTurn(messages: messages, log: testLogger)
    Task { for await _ in ts.events { } }
    let result = try await ts.result.value
    #expect(result.messages.count == 2)
    #expect(result.messages[0].role == .user)
    #expect(result.messages[0].content == "hello")
    #expect(result.messages[1].role == .assistant)
    #expect(result.messages[1].content == "reply")
  }

  @Test func streamTurnResultMessagesAfterToolRound() async throws {
    let toolChunks = [
      sseChunk(#"{"id":"1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"fake_tool","arguments":"{}"}}]}}]}"#),
      doneChunk(),
    ]
    let replyChunks = [
      sseChunk(#"{"id":"2","choices":[{"index":0,"delta":{"content":"done"}}]}"#),
      doneChunk(),
    ]
    let agent = makeAgent(chunksForCall: [toolChunks, replyChunks], tools: [FakeTool()])
    let ts = agent.streamTurn(messages: [], log: testLogger)
    Task { for await _ in ts.events { } }
    let result = try await ts.result.value
    #expect(result.outcome == .completed)
    #expect(result.messages.count == 3)
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
      guard case .apiHTTPError(let code, _, _) = error else { #expect(Bool(false)); return }
      #expect(code == 500)
    } catch {
      #expect(Bool(false))
    }
  }

  @Test func streamTurnStreamFinishesOnError() async {
    let agent = makeAgent(statusCode: 500, chunks: [errorBody("boom")])
    let ts = agent.streamTurn(messages: [], log: testLogger)
    var eventCount = 0
    for await _ in ts.events { eventCount += 1 }
    let didThrow: Bool
    do { _ = try await ts.result.value; didThrow = false }
    catch { didThrow = true }
    #expect(didThrow)
    #expect(eventCount == 0)
  }

  // MARK: - streamTurn: shouldAbortTurn

  @Test func streamTurnAbortReturnsInterrupted() async throws {
    let chunks = [
      sseChunk(#"{"id":"1","choices":[{"index":0,"delta":{"content":"hello"}}]}"#),
      doneChunk(),
    ]
    let agent = makeAgent(chunks: chunks)
    let ts = agent.streamTurn(messages: [], log: testLogger, shouldAbortTurn: { true })
    Task { for await _ in ts.events { } }
    let result = try await ts.result.value
    #expect(result.outcome == .interrupted)
  }
}
