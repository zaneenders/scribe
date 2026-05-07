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

  // MARK: - runTurn

  @Test func runTurnCompletesWithAnswerText() async throws {
    let chunks = [
      sseChunk(
        #"{"id":"1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"done"}}]}"#
      ),
      doneChunk(),
    ]
    let agent = makeAgent(chunks: chunks)

    var messages: [Components.Schemas.ChatMessage] = []
    let outcome = try await agent.runTurn(
      messages: &messages,
      log: testLogger,
      onEvent: { _ in }
    )
    #expect(outcome == .completed)
  }

  @Test func runTurnPassesMaxToolRounds() async throws {
    // Return a tool call that would loop forever, but maxToolRounds=1 stops it.
    let chunks = [
      sseChunk(
        #"{"id":"1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"fake_tool","arguments":"{}"}}]}}]}"#
      ),
      doneChunk(),
    ]
    let agent = makeAgent(chunks: chunks, tools: [FakeTool()])

    var messages: [Components.Schemas.ChatMessage] = []
    let outcome = try await agent.runTurn(
      messages: &messages,
      log: testLogger,
      maxToolRounds: 1,
      onEvent: { _ in }
    )
    #expect(outcome == .toolRoundLimit(rounds: 1))
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
}
