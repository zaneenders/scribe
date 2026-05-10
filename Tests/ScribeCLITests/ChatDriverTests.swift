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

// MARK: - Fake tool

private struct FakeTool: ScribeTool {
  static var name: String { "fake_tool" }
  static var description: String { "A fake tool for testing." }
  static var parameters: [ScribeToolParameter] { [] }
  static var promptHint: String? { nil }
  struct Result: Encodable { let ok = true }
  func run(arguments: String, workingDirectory: ScribeCore.ScribeFilePath) async throws -> Encodable { Result() }
}

// MARK: - SSE chunk helpers

private func sseChunk(_ json: String) -> HTTPBody.ByteChunk {
  ArraySlice("data: \(json)\n\n".utf8)
}
private func doneChunk() -> HTTPBody.ByteChunk {
  ArraySlice("data: [DONE]\n\n".utf8)
}

// MARK: - Convenience

private let testLogger = Logger(label: "test.chatdriver")

private func makeAgent(
  chunks: [HTTPBody.ByteChunk],
  tools: [any ScribeTool] = []
) -> ScribeAgent {
  let transport = FakeClientTransport(statusCode: 200, responseBodyChunks: chunks)
  let client = Client(serverURL: URL(string: "http://test")!, transport: transport)
  return ScribeAgent(
    client: client,
    model: "test-model",
    systemPrompt: "You are a test agent.",
    tools: tools,
    workingDirectory: ScribeFilePath("/tmp")
  )
}

private func makeAgent(
  chunksForCall: [[HTTPBody.ByteChunk]],
  tools: [any ScribeTool] = []
) -> ScribeAgent {
  let transport = FakeClientTransport(
    statusCode: 200, responseBodyChunksForCall: chunksForCall)
  let client = Client(serverURL: URL(string: "http://test")!, transport: transport)
  return ScribeAgent(
    client: client,
    model: "test-model",
    systemPrompt: "You are a test agent.",
    tools: tools,
    workingDirectory: ScribeFilePath("/tmp")
  )
}

// MARK: - ChatDriver tests

@Suite
struct ChatDriverTests {

  // MARK: - Full turn transcript

  @Test func headlessFullTurnProducesCorrectTranscript() async throws {
    let chunks = [
      sseChunk(#"{"id":"1","choices":[{"index":0,"delta":{"content":"Hello, world!"}}]}"#),
      doneChunk(),
    ]
    let agent = makeAgent(chunks: chunks)

    let result = try await ChatDriver().run(
      config: ChatDriver.Config(agent: agent),
      input: ["say hello"],
      log: testLogger
    )

    // Final transcript should contain user message and assistant response.
    let transcriptText = result.finalTranscript
      .flatMap { $0.spans }
      .map { $0.text }
      .joined()

    #expect(transcriptText.contains("you:"))
    #expect(transcriptText.contains("Hello, world!"))
    #expect(result.outcome == .completed)
  }

  // MARK: - Tool round transcript

  @Test func headlessToolRoundCreatesCorrectTranscript() async throws {
    let toolChunks = [
      sseChunk(#"{"id":"1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"fake_tool","arguments":"{}"}}]}}]}"#),
      doneChunk(),
    ]
    let replyChunks = [
      sseChunk(#"{"id":"2","choices":[{"index":0,"delta":{"content":"done"}}]}"#),
      doneChunk(),
    ]
    let agent = makeAgent(chunksForCall: [toolChunks, replyChunks], tools: [FakeTool()])

    let result = try await ChatDriver().run(
      config: ChatDriver.Config(agent: agent),
      input: ["use the tool"],
      log: testLogger
    )

    // Should contain tool round header.
    let transcriptText = result.finalTranscript
      .flatMap { $0.spans }
      .map { $0.text }
      .joined()
    #expect(transcriptText.contains("tool round 1"))
    #expect(transcriptText.contains("fake_tool"))
    #expect(result.outcome == .completed)
  }

  // MARK: - Empty input

  @Test func headlessEmptyInputIsSkipped() async throws {
    let chunks = [
      sseChunk(#"{"id":"1","choices":[{"index":0,"delta":{"content":"ok"}}]}"#),
      doneChunk(),
    ]
    let agent = makeAgent(chunks: chunks)

    let result = try await ChatDriver().run(
      config: ChatDriver.Config(agent: agent),
      input: [""],
      log: testLogger
    )

    // No turns dispatched for empty input.
    #expect(result.finalTranscript.isEmpty)
    #expect(result.transcriptHistory.isEmpty)
  }

  // MARK: - Exit command

  @Test func headlessExitStopsEarly() async throws {
    let chunks = [
      sseChunk(#"{"id":"1","choices":[{"index":0,"delta":{"content":"first"}}]}"#),
      doneChunk(),
    ]
    let agent = makeAgent(chunks: chunks)

    let result = try await ChatDriver().run(
      config: ChatDriver.Config(agent: agent),
      input: ["first turn", "exit", "should not run"],
      log: testLogger
    )

    let transcriptText = result.finalTranscript
      .flatMap { $0.spans }
      .map { $0.text }
      .joined()
    #expect(transcriptText.contains("first"))
    #expect(!transcriptText.contains("should not run"))
  }

  // MARK: - Multiple turns

  @Test func headlessMultipleTurns() async throws {
    let chunks = [
      sseChunk(#"{"id":"1","choices":[{"index":0,"delta":{"content":"response one"}}]}"#),
      doneChunk(),
    ]
    let agent = makeAgent(chunks: chunks)

    let result = try await ChatDriver().run(
      config: ChatDriver.Config(agent: agent),
      input: ["turn one", "turn two"],
      log: testLogger
    )

    let transcriptText = result.finalTranscript
      .flatMap { $0.spans }
      .map { $0.text }
      .joined()
    #expect(transcriptText.contains("response one"))
    // Each turn adds user + assistant lines
    let youCount = transcriptText.components(separatedBy: "you:").count - 1
    #expect(youCount == 2)
  }

  // MARK: - Transcript history

  @Test func headlessCapturesTranscriptHistory() async throws {
    let chunks = [
      sseChunk(#"{"id":"1","choices":[{"index":0,"delta":{"content":"hello"}}]}"#),
      doneChunk(),
    ]
    let agent = makeAgent(chunks: chunks)

    let result = try await ChatDriver().run(
      config: ChatDriver.Config(agent: agent),
      input: ["say hi"],
      log: testLogger
    )

    // Should have snapshots: userSubmitted, enterAssistantSection, appendAssistantText, finalizeAssistantStream, blankLine, turnComplete
    #expect(result.transcriptHistory.count >= 2)

    // First event should be userSubmitted.
    let firstSnapshot = result.transcriptHistory.first!
    if case .userSubmitted(let text) = firstSnapshot.event {
      #expect(text == "say hi")
    } else {
      #expect(Bool(false), "first event should be userSubmitted")
    }
  }

  // MARK: - Outcome propagation

  @Test func headlessPropagatesTurnOutcome() async throws {
    let chunks = [
      sseChunk(#"{"id":"1","choices":[{"index":0,"delta":{"content":"x"}}]}"#),
      doneChunk(),
    ]
    let agent = makeAgent(chunks: chunks)

    let result = try await ChatDriver().run(
      config: ChatDriver.Config(agent: agent),
      input: ["test"],
      log: testLogger
    )

    #expect(result.outcome == .completed)
  }
}
