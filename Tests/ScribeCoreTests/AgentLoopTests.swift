import Foundation
import HTTPTypes
import Logging
import OpenAPIRuntime
import ScribeLLM
import Synchronization
import Testing

@testable import ScribeCore

// MARK: - Fake Client Transport

private final class FakeClientTransport: ClientTransport, Sendable {
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

// MARK: - Fake tools

private struct FakeTool: ScribeTool {
  static var name: String { "fake_tool" }
  static var description: String { "A fake tool for testing." }
  static var parameters: [ScribeToolParameter] { [] }
  static var promptHint: String? { nil }
  struct Result: Encodable { let ok = true }
  func run(arguments: String, workingDirectory: ScribeCore.ScribeFilePath) async throws -> Encodable { Result() }
}

/// A tool that throws `AgentTurnInterruptedError` directly from `run`.
private struct InterruptedTool: ScribeTool {
  static var name: String { "interrupted_tool" }
  static var description: String { "Throws AgentTurnInterruptedError." }
  static var parameters: [ScribeToolParameter] { [] }
  static var promptHint: String? { nil }
  struct Result: Encodable { let ok = true }
  func run(arguments: String, workingDirectory: ScribeCore.ScribeFilePath) async throws -> Encodable {
    throw AgentTurnInterruptedError()
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

private let testLogger = Logger(label: "test.agentloop")

/// Run an async operation with a timeout. Throws if the operation doesn't
/// complete within the given duration.
private func withTimeout<T: Sendable>(
  seconds: Double,
  _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
  try await withThrowingTaskGroup(of: T.self) { group in
    group.addTask {
      try await operation()
    }
    group.addTask {
      try await Task.sleep(for: .seconds(seconds))
      throw CancellationError()
    }
    let result = try await group.next()!
    group.cancelAll()
    return result
  }
}

/// Build an `AgentLoopConfig` for use with `runAgentLoop`.
private func makeConfig(
  statusCode: Int = 200,
  chunks: [HTTPBody.ByteChunk],
  model: String = "test-model",
  tools: [any ScribeTool] = [],
  temperature: Double = 0,
  maxToolRounds: Int = .max
) -> AgentLoopConfig {
  let transport = FakeClientTransport(statusCode: statusCode, responseBodyChunks: chunks)
  let client = Client(serverURL: URL(string: "http://test")!, transport: transport)
  return AgentLoopConfig(
    model: model,
    client: client,
    registry: ToolRegistry(tools: tools),
    temperature: temperature,
    maxToolRounds: maxToolRounds, workingDirectory: ScribeFilePath("/tmp")
  )
}

/// Run the agent loop with a single string prompt.
private func runLoop(
  prompt: String,
  context: AgentContext = AgentContext(systemPrompt: "You are a test agent.", messages: []),
  config: AgentLoopConfig,
  shouldAbortTurn: @escaping @Sendable () -> Bool = { false }
) async throws -> (messages: [Components.Schemas.ChatMessage], termination: LoopTermination) {
  let userMsg = Components.Schemas.ChatMessage(role: .user, content: prompt)
  return try await runAgentLoop(
    promptMessages: [userMsg],
    context: context,
    config: config,
    emit: { _ in },
    log: testLogger,
    shouldAbortTurn: shouldAbortTurn
  )
}

// MARK: - LoopTermination pattern helpers

/// Lightweight match for `LoopTermination` since it can't synthesize Equatable.
private func expectTermination(_ actual: LoopTermination, _ expected: LoopTermination) {
  switch (actual, expected) {
  case (.completed, .completed): return
  case (.interrupted, .interrupted): return
  case (.toolRoundLimit(let a), .toolRoundLimit(let b)) where a == b: return
  default:
    #expect(Bool(false), Comment(rawValue: "Expected \(expected), got \(actual)"))
  }
}

// MARK: - Tests

@Suite
struct AgentLoopTests {

  // MARK: - Basic completions

  @Test func completesWithAssistantReply() async throws {
    let chunks = [
      sseChunk(#"{"id":"1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"reply"}}]}"#),
      doneChunk(),
    ]
    let (messages, termination) = try await runLoop(
      prompt: "hello", config: makeConfig(chunks: chunks))
    expectTermination(termination, .completed)
    #expect(messages.count == 2)  // user + assistant
    #expect(messages[0].role == .user)
    #expect(messages[0].content == "hello")
    #expect(messages[1].role == .assistant)
    #expect(messages[1].content == "reply")
  }

  @Test func completesWithEmptyAssistantText() async throws {
    // Assistant returns no content and no tool calls
    let chunks = [
      sseChunk(#"{"id":"1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{}}]}"#),
      doneChunk(),
    ]
    let (messages, termination) = try await runLoop(
      prompt: "hello", config: makeConfig(chunks: chunks))
    expectTermination(termination, .completed)
    #expect(messages.count == 2)
    #expect(messages[1].role == .assistant)
    #expect(messages[1].content == "")
  }

  // MARK: - Tool round limit

  @Test func toolRoundLimit() async throws {
    let chunks = [
      sseChunk(
        #"{"id":"1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"fake_tool","arguments":"{}"}}]}}]}"#
      ),
      doneChunk(),
    ]
    let config = makeConfig(chunks: chunks, tools: [FakeTool()], maxToolRounds: 1)
    let (messages, termination) = try await runLoop(
      prompt: "test", config: config)
    expectTermination(termination, .toolRoundLimit(rounds: 1))
    // Only the user message survives (round messages rolled back)
    #expect(messages.count == 1)
    #expect(messages[0].role == .user)
  }

  // MARK: - Single tool round → completion

  @Test func toolRoundThenCompletion() async throws {
    let toolChunks = [
      sseChunk(
        #"{"id":"1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"fake_tool","arguments":"{}"}}]}}]}"#
      ),
      doneChunk(),
    ]
    let replyChunks = [
      sseChunk(#"{"id":"2","choices":[{"index":0,"delta":{"content":"done"}}]}"#),
      doneChunk(),
    ]
    let transport = FakeClientTransport(
      statusCode: 200, responseBodyChunksForCall: [toolChunks, replyChunks])
    let client = Client(serverURL: URL(string: "http://test")!, transport: transport)
    let config = AgentLoopConfig(
      model: "test-model",
      client: client,
      registry: ToolRegistry(tools: [FakeTool()]),
      temperature: 0,
      maxToolRounds: .max, workingDirectory: ScribeFilePath("/tmp")
    )
    let (messages, termination) = try await runLoop(
      prompt: "test", config: config)
    expectTermination(termination, .completed)
    // user + assistant(tool-calling) + tool(result) + assistant(done)
    #expect(messages.count == 4)
    #expect(messages[0].role == .user)
    #expect(messages[1].role == .assistant)
    #expect(messages[2].role == .tool)
    #expect(messages[2].toolCallId == "c1")
    #expect(messages[3].role == .assistant)
    #expect(messages[3].content == "done")
  }

  // MARK: - Abort: before-http

  @Test func abortBeforeHTTP() async throws {
    let chunks = [
      sseChunk(#"{"id":"1","choices":[{"index":0,"delta":{"content":"hello"}}]}"#),
      doneChunk(),
    ]
    let (messages, termination) = try await runLoop(
      prompt: "test",
      config: makeConfig(chunks: chunks),
      shouldAbortTurn: { true }
    )
    expectTermination(termination, .interrupted)
    // prompt message is appended before abort check
    #expect(messages.count == 1)
    #expect(messages[0].role == .user)
  }

  // MARK: - Abort: post-stream-pre-tools

  /// In a single-SSE-chunk stream the calls are:
  ///   0: before-http  1: mid-stream  2: post-stream-pre-tools
  @Test func abortPostStreamPreTools() async throws {
    let chunks = [
      sseChunk(
        #"{"id":"1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"fake_tool","arguments":"{}"}}]}}]}"#
      ),
      doneChunk(),
    ]
    let counter = Atomic<Int>(0)
    let shouldAbortTurn: @Sendable () -> Bool = {
      let c = counter.load(ordering: .sequentiallyConsistent)
      counter.store(c + 1, ordering: .sequentiallyConsistent)
      return c == 2  // post-stream-pre-tools check
    }
    let (messages, termination) = try await runLoop(
      prompt: "test",
      config: makeConfig(chunks: chunks, tools: [FakeTool()]),
      shouldAbortTurn: shouldAbortTurn
    )
    expectTermination(termination, .interrupted)
    // prompt message remains; round messages rolled back
    #expect(messages.count == 1)
    #expect(messages[0].role == .user)
  }

  // MARK: - Abort: pre-tool

  /// Calls: 0:before-http 1:mid-stream 2:post-stream-pre-tools 3:pre-tool(inv[0])
  @Test func abortPreTool() async throws {
    let chunks = [
      sseChunk(
        #"{"id":"1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"fake_tool","arguments":"{}"}}]}}]}"#
      ),
      doneChunk(),
    ]
    let counter = Atomic<Int>(0)
    let shouldAbortTurn: @Sendable () -> Bool = {
      let c = counter.load(ordering: .sequentiallyConsistent)
      counter.store(c + 1, ordering: .sequentiallyConsistent)
      return c == 3  // pre-tool check
    }
    let (messages, termination) = try await runLoop(
      prompt: "test",
      config: makeConfig(chunks: chunks, tools: [FakeTool()]),
      shouldAbortTurn: shouldAbortTurn
    )
    expectTermination(termination, .interrupted)
    #expect(messages.count == 1)
    #expect(messages[0].role == .user)
  }

  // MARK: - Abort: during tool execution (AgentTurnInterruptedError from registry)

  /// Calls: 0:before-http 1:mid-stream 2:post-stream-pre-tools 3:pre-tool
  ///        4:registry.before-start  5:registry.polling-loop
  /// Return true at call 4 → before-start check throws AgentTurnInterruptedError.
  @Test func abortDuringToolExecutionViaBeforeStart() async throws {
    let chunks = [
      sseChunk(
        #"{"id":"1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"fake_tool","arguments":"{}"}}]}}]}"#
      ),
      doneChunk(),
    ]
    let counter = Atomic<Int>(0)
    let shouldAbortTurn: @Sendable () -> Bool = {
      let c = counter.load(ordering: .sequentiallyConsistent)
      counter.store(c + 1, ordering: .sequentiallyConsistent)
      return c == 4  // registry.run before-start check
    }
    let (messages, termination) = try await runLoop(
      prompt: "test",
      config: makeConfig(chunks: chunks, tools: [FakeTool()]),
      shouldAbortTurn: shouldAbortTurn
    )
    expectTermination(termination, .interrupted)
    #expect(messages.count == 1)
  }

  // MARK: - Unknown tool

  @Test func unknownToolReturnsJSONError() async throws {
    try await withTimeout(seconds: 5) {
      // LLM calls a tool not in the registry, then recovers.
      let toolChunks = [
        sseChunk(
          #"{"id":"1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"nonexistent_tool","arguments":"{}"}}]}}]}"#
        ),
        doneChunk(),
      ]
      let replyChunks = [
        sseChunk(#"{"id":"2","choices":[{"index":0,"delta":{"content":"all good"}}]}"#),
        doneChunk(),
      ]
      let transport = FakeClientTransport(
        statusCode: 200, responseBodyChunksForCall: [toolChunks, replyChunks])
      let client = Client(serverURL: URL(string: "http://test")!, transport: transport)
      let config = AgentLoopConfig(
        model: "test-model",
        client: client,
        registry: ToolRegistry(tools: [FakeTool()]),
        temperature: 0,
        maxToolRounds: .max, workingDirectory: ScribeFilePath("/tmp")
      )
      let (messages, termination) = try await runLoop(
        prompt: "test",
        config: config
      )
      expectTermination(termination, .completed)
      // The unknown tool error becomes a tool message with jsonError.
      let toolMessages = messages.filter { $0.role == .tool }
      #expect(toolMessages.count >= 1)
      if let toolMsg = toolMessages.first {
        #expect(toolMsg.toolCallId == "c1")
        #expect(toolMsg.content?.contains("unknown tool") == true)
      }
    }
  }

  // MARK: - HTTP error paths

  @Test func http404Error() async throws {
    let config = makeConfig(statusCode: 404, chunks: [errorBody("not found")])
    do {
      _ = try await runLoop(prompt: "test", config: config)
      #expect(Bool(false), "expected error")
    } catch let error as ScribeError {
      guard case .apiHTTPError(let code, _, let hint) = error else {
        #expect(Bool(false))
        return
      }
      #expect(code == 404)
      #expect(hint == " Set api.baseUrl to the host only (no /v1).")
    }
  }

  @Test func http404ModelNotFoundHint() async throws {
    let config = makeConfig(
      statusCode: 404,
      chunks: [errorBody("The model `gpt-999` was not found")])
    do {
      _ = try await runLoop(prompt: "test", config: config)
      #expect(Bool(false), "expected error")
    } catch let error as ScribeError {
      guard case .apiHTTPError(let code, _, let hint) = error else {
        #expect(Bool(false))
        return
      }
      #expect(code == 404)
      #expect(hint == " The configured model was not found.")
    }
  }

  @Test func http400ErrorWarningLevel() async throws {
    let config = makeConfig(statusCode: 400, chunks: [errorBody("bad request")])
    do {
      _ = try await runLoop(prompt: "test", config: config)
      #expect(Bool(false), "expected error")
    } catch let error as ScribeError {
      guard case .apiHTTPError(let code, let detail, let hint) = error else {
        #expect(Bool(false))
        return
      }
      #expect(code == 400)
      #expect(detail.contains("bad request"))
      #expect(hint == nil)
    }
  }

  @Test func http500ErrorWithLongDetail() async throws {
    try await withTimeout(seconds: 5) {
      // Detail > 512 chars — full detail preserved in the error value
      let longMessage = String(repeating: "x", count: 600)
      let config = makeConfig(statusCode: 500, chunks: [errorBody(longMessage)])
      do {
        _ = try await runLoop(prompt: "test", config: config)
        #expect(Bool(false), "expected error")
      } catch let error as ScribeError {
        guard case .apiHTTPError(let code, let detail, _) = error else {
          #expect(Bool(false))
          return
        }
        #expect(code == 500)
        // detail is the full HTTP response body, so it contains the long message
        #expect(detail.contains(longMessage))
      }
    }
  }

  // MARK: - Usage without completion tokens

  @Test func usageWithoutCompletionTokens() async throws {
    let chunks = [
      sseChunk(#"{"id":"1","choices":[{"index":0,"delta":{"content":"x"}}]}"#),
      sseChunk(#"{"id":"1","choices":[],"usage":{"prompt_tokens":10,"total_tokens":10}}"#),
      doneChunk(),
    ]
    let events = Mutex<[TranscriptEvent]>([])
    let userMsg = Components.Schemas.ChatMessage(role: .user, content: "test")
    let (_, termination) = try await runAgentLoop(
      promptMessages: [userMsg],
      context: AgentContext(systemPrompt: "test", messages: []),
      config: makeConfig(chunks: chunks),
      emit: { event in events.withLock { $0.append(event) } },
      log: testLogger,
      shouldAbortTurn: { false }
    )
    expectTermination(termination, .completed)
    let captured = events.withLock { $0 }
    let usageEvents = captured.compactMap { (e: TranscriptEvent) -> (Components.Schemas.CompletionUsage, Double?)? in
      if case .usage(let u, let tps) = e { return (u, tps) }
      return nil
    }
    #expect(usageEvents.count == 1)
    #expect(usageEvents[0].0.promptTokens == 10)
    #expect(usageEvents[0].0.completionTokens == nil)
    #expect(usageEvents[0].1 == nil)  // tps nil because no completion tokens
  }

  // MARK: - Reasoning content

  @Test func reasoningContentIncludedInAssistantMessage() async throws {
    let chunks = [
      sseChunk(
        #"{"id":"1","choices":[{"index":0,"delta":{"reasoning_content":"Let me think...","content":"answer"}}]}"#),
      doneChunk(),
    ]
    let (messages, termination) = try await runLoop(
      prompt: "test", config: makeConfig(chunks: chunks))
    expectTermination(termination, .completed)
    #expect(messages.count == 2)
    #expect(messages[1].role == .assistant)
    #expect(messages[1].content == "answer")
    #expect(messages[1].reasoningContent == "Let me think...")
  }

  // MARK: - Empty prompt messages

  @Test func emptyPromptMessagesWithInitialContext() async throws {
    let chunks = [
      sseChunk(#"{"id":"1","choices":[{"index":0,"delta":{"content":"reply"}}]}"#),
      doneChunk(),
    ]
    let initialMessages: [Components.Schemas.ChatMessage] = [
      .init(role: .system, content: "System prompt"),
      .init(role: .user, content: "previous question"),
      .init(role: .assistant, content: "previous answer"),
    ]
    let context = AgentContext(
      systemPrompt: "System prompt", messages: initialMessages)
    let (messages, termination) = try await runAgentLoop(
      promptMessages: [],
      context: context,
      config: makeConfig(chunks: chunks),
      emit: { _ in },
      log: testLogger,
      shouldAbortTurn: { false }
    )
    expectTermination(termination, .completed)
    // Only the new assistant message is returned
    #expect(messages.count == 1)
    #expect(messages[0].role == .assistant)
    #expect(messages[0].content == "reply")
  }

  // MARK: - Multiple tool calls in one round

  @Test func multipleToolCallsInOneRound() async throws {
    let toolChunks = [
      sseChunk(
        #"{"id":"1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"fake_tool","arguments":"{}"}},{"index":1,"id":"c2","type":"function","function":{"name":"fake_tool","arguments":"{}"}}]}}]}"#
      ),
      doneChunk(),
    ]
    let replyChunks = [
      sseChunk(#"{"id":"2","choices":[{"index":0,"delta":{"content":"all done"}}]}"#),
      doneChunk(),
    ]
    let transport = FakeClientTransport(
      statusCode: 200, responseBodyChunksForCall: [toolChunks, replyChunks])
    let client = Client(serverURL: URL(string: "http://test")!, transport: transport)
    let config = AgentLoopConfig(
      model: "test-model",
      client: client,
      registry: ToolRegistry(tools: [FakeTool()]),
      temperature: 0,
      maxToolRounds: .max, workingDirectory: ScribeFilePath("/tmp")
    )
    let (messages, termination) = try await runLoop(
      prompt: "test", config: config)
    expectTermination(termination, .completed)
    // user + assistant(tool-calling) + tool(c1) + tool(c2) + assistant(done)
    #expect(messages.count == 5)
    #expect(messages[0].role == .user)
    #expect(messages[1].role == .assistant)
    #expect(messages[2].role == .tool)
    #expect(messages[2].toolCallId == "c1")
    #expect(messages[3].role == .tool)
    #expect(messages[3].toolCallId == "c2")
    #expect(messages[4].role == .assistant)
    #expect(messages[4].content == "all done")
  }

  // MARK: - Tool that throws (error is caught and converted to jsonError)

  @Test func toolThatThrowsIsConvertedToJSONError() async throws {
    let chunks = [
      sseChunk(
        #"{"id":"1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"interrupted_tool","arguments":"{}"}}]}}]}"#
      ),
      doneChunk(),
    ]
    let replyChunks = [
      sseChunk(#"{"id":"2","choices":[{"index":0,"delta":{"content":"recovered"}}]}"#),
      doneChunk(),
    ]
    let transport = FakeClientTransport(
      statusCode: 200, responseBodyChunksForCall: [chunks, replyChunks])
    let client = Client(serverURL: URL(string: "http://test")!, transport: transport)
    let config = AgentLoopConfig(
      model: "test-model",
      client: client,
      registry: ToolRegistry(tools: [InterruptedTool()]),
      temperature: 0,
      maxToolRounds: .max, workingDirectory: ScribeFilePath("/tmp")
    )
    let (messages, termination) = try await runLoop(
      prompt: "test", config: config)
    // The tool throws AgentTurnInterruptedError from run(), but ToolRegistry
    // catches it in the tool task and converts to jsonError. So it does NOT
    // terminate the loop — it becomes a tool message with an error.
    expectTermination(termination, .completed)
    #expect(messages.count == 4)
    #expect(messages[2].role == .tool)
    #expect(messages[2].content?.contains("ok") == true)
  }

  // MARK: - AgentTurnInterruptedError mid-stream

  @Test func midStreamAbortThrowsInterrupted() async throws {
    try await withTimeout(seconds: 5) {
      // Abort that triggers during the SSE stream processing
      let chunks = [
        sseChunk(#"{"id":"1","choices":[{"index":0,"delta":{"content":"hello"}}]}"#),
        doneChunk(),
      ]
      let counter = Atomic<Int>(0)
      let shouldAbortTurn: @Sendable () -> Bool = {
        let c = counter.load(ordering: .sequentiallyConsistent)
        counter.store(c + 1, ordering: .sequentiallyConsistent)
        return c == 1  // mid-stream check (call 0: before-http, call 1: mid-stream)
      }
      let (messages, termination) = try await runLoop(
        prompt: "test",
        config: makeConfig(chunks: chunks),
        shouldAbortTurn: shouldAbortTurn
      )
      expectTermination(termination, .interrupted)
      _ = messages  // silence unused warning
    }
  }
}

// MARK: - Error body helper

private func errorBody(_ message: String) -> HTTPBody.ByteChunk {
  // Escape double quotes in the message
  let escaped = message.replacingOccurrences(of: "\"", with: "\\\"")
  return ArraySlice(#"{"error":{"message":"\#(escaped)"}}"#.utf8)
}
