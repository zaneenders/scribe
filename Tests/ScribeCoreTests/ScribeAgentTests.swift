import Foundation
import HTTPTypes
import Logging
import OpenAPIRuntime
import ScribeCore
import ScribeLLM
import Synchronization
import Testing

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

// MARK: - Fake tool

private struct FakeTool: ScribeTool {
  static var name: String { "fake_tool" }
  static var description: String { "A fake tool for testing." }
  static var parameters: [ScribeToolParameter] { [] }
  static var promptHint: String? { nil }
  struct Result: Encodable { let ok = true }
  func run(arguments: String, workingDirectory: ScribeCore.ScribeFilePath) async throws -> Encodable { Result() }
}

/// Sleeps until cancelled — used by `promptAbortReturnsInterrupted` to keep
/// the agent loop parked in its tool watch task while the test fires
/// `agent.abort()`. The 60-second sleep is throwing so the watch task's
/// cancellation surfaces as a clean abort rather than a hang.
private struct SleepyAgentTool: ScribeTool {
  static var name: String { "sleepy" }
  static var description: String { "Sleeps until cancelled." }
  static var parameters: [ScribeToolParameter] { [] }
  static var promptHint: String? { nil }
  struct Result: Encodable { let ok = true }
  func run(arguments: String, workingDirectory: ScribeCore.ScribeFilePath) async throws -> Encodable {
    try await Task.sleep(for: .seconds(60))
    return Result()
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
  return ScribeAgent(
    client: client,
    model: model,
    systemPrompt: "You are a test agent.",
    tools: tools,
    initialMessages: [],
    workingDirectory: ScribeFilePath("/tmp"),
    reasoningEnabled: nil
  )
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
  return ScribeAgent(
    client: client,
    model: model,
    systemPrompt: "You are a test agent.",
    tools: tools,
    initialMessages: [],
    workingDirectory: ScribeFilePath("/tmp"),
    reasoningEnabled: nil
  )
}

// MARK: - Tests

@Suite
struct ScribeAgentTests {

  // MARK: - prompt: outcome

  @Test func promptCompletesWithAnswerText() async throws {
    let chunks = [
      sseChunk(#"{"id":"1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"done"}}]}"#),
      doneChunk(),
    ]
    let agent = makeAgent(chunks: chunks)
    let ts = await agent.prompt("hello", log: testLogger)
    Task { for await _ in ts.events {} }
    let result = try await ts.result.value
    #expect(result.outcome == .completed)
  }

  @Test func promptRespectsMaxToolRounds() async throws {
    let chunks = [
      sseChunk(
        #"{"id":"1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"fake_tool","arguments":"{}"}}]}}]}"#
      ),
      doneChunk(),
    ]
    let agent = makeAgent(chunks: chunks, tools: [FakeTool()])
    let options = AgentRunOptions(maxToolRounds: 1)
    let ts = await agent.prompt("test", options: options, log: testLogger)
    Task { for await _ in ts.events {} }
    let result = try await ts.result.value
    #expect(result.outcome == .toolRoundLimit(rounds: 1))
  }

  // MARK: - prompt: events

  @Test func promptYieldsAssistantTextEvents() async throws {
    let chunks = [
      sseChunk(#"{"id":"1","choices":[{"index":0,"delta":{"content":"hello"}}]}"#),
      sseChunk(#"{"id":"1","choices":[{"index":0,"delta":{"content":" world"}}]}"#),
      doneChunk(),
    ]
    let agent = makeAgent(chunks: chunks)
    let ts = await agent.prompt("test", log: testLogger)
    var texts: [String] = []
    for await event in ts.events {
      if case .appendAssistantText(_, let text) = event { texts.append(text) }
    }
    let result = try await ts.result.value
    #expect(texts == ["hello", " world"])
    #expect(result.outcome == .completed)
  }

  @Test func promptYieldsToolInvocationEvents() async throws {
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
    let agent = makeAgent(chunksForCall: [toolChunks, replyChunks], tools: [FakeTool()])
    let ts = await agent.prompt("test", log: testLogger)
    var events: [TranscriptEvent] = []
    for await event in ts.events { events.append(event) }
    let result = try await ts.result.value
    #expect(result.outcome == .completed)
    let hasInvocation = events.contains(where: {
      if case .toolInvocation(let name, _, _) = $0, name == "fake_tool" { return true }
      return false
    })
    #expect(hasInvocation)
  }

  @Test func promptYieldsUsageEvent() async throws {
    let chunks = [
      sseChunk(#"{"id":"1","choices":[{"index":0,"delta":{"content":"x"}}]}"#),
      sseChunk(#"{"id":"1","choices":[],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}"#),
      doneChunk(),
    ]
    let agent = makeAgent(chunks: chunks)
    let ts = await agent.prompt("test", log: testLogger)
    var events: [TranscriptEvent] = []
    for await event in ts.events { events.append(event) }
    _ = try await ts.result.value
    let hasUsage = events.contains(where: {
      if case .usage(let u, _) = $0, u.promptTokens == 10, u.completionTokens == 5, u.totalTokens == 15 { return true }
      return false
    })
    #expect(hasUsage)
  }

  // MARK: - prompt: result.messages

  @Test func promptResultMessagesContainsAssistantMessage() async throws {
    let chunks = [
      sseChunk(#"{"id":"1","choices":[{"index":0,"delta":{"content":"reply"}}]}"#),
      doneChunk(),
    ]
    let agent = makeAgent(chunks: chunks)
    let ts = await agent.prompt("hello", log: testLogger)
    Task { for await _ in ts.events {} }
    let result = try await ts.result.value
    // The agent auto-injects the system message at construction time when
    // `initialMessages` doesn't already contain one — see ScribeAgent.swift.
    #expect(result.messages.count == 3)  // system + user + assistant
    #expect(result.messages[0].role == .system)
    #expect(result.messages[1].role == .user)
    #expect(result.messages[1].content == "hello")
    #expect(result.messages[2].role == .assistant)
    #expect(result.messages[2].content == "reply")
  }

  @Test func promptResultMessagesAfterToolRound() async throws {
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
    let agent = makeAgent(chunksForCall: [toolChunks, replyChunks], tools: [FakeTool()])
    let ts = await agent.prompt("test", log: testLogger)
    Task { for await _ in ts.events {} }
    let result = try await ts.result.value
    #expect(result.outcome == .completed)
    // Messages: system + user(prompt) + assistant(tool-calling) + tool(result) + assistant(done)
    #expect(result.messages.count == 5)
    #expect(result.messages[0].role == .system)
    #expect(result.messages[1].role == .user)
    #expect(result.messages[2].role == .assistant)
    #expect(result.messages[3].role == .tool)
    #expect(result.messages[3].toolCallId == "c1")
    #expect(result.messages[4].role == .assistant)
    #expect(result.messages[4].content == "done")
  }

  // MARK: - prompt: error propagation

  @Test func promptPropagatesHTTPError() async {
    let agent = makeAgent(statusCode: 500, chunks: [errorBody("boom")])
    let ts = await agent.prompt("test", log: testLogger)
    Task { for await _ in ts.events {} }
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

  @Test func promptStreamFinishesOnError() async {
    let agent = makeAgent(statusCode: 500, chunks: [errorBody("boom")])
    let ts = await agent.prompt("test", log: testLogger)
    var eventCount = 0
    for await _ in ts.events { eventCount += 1 }
    let didThrow: Bool
    do {
      _ = try await ts.result.value
      didThrow = false
    } catch { didThrow = true }
    #expect(didThrow)
    #expect(eventCount == 0)
  }

  // MARK: - prompt: abort

  /// Verify `agent.abort()` interrupts an in-flight turn. We can't pre-set
  /// abort before `prompt()` because the agent clears its private notifier
  /// at the top of each turn (so a stray Ctrl+C between prompts can't
  /// bleed into the next one). Instead we start a tool call against a
  /// long-sleeping tool so the loop is stuck in the watch task, then call
  /// `abort()` to wake it.
  @Test func promptAbortReturnsInterrupted() async throws {
    let toolCallChunks = [
      sseChunk(
        #"{"id":"1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"sleepy","arguments":"{}"}}]}}]}"#
      ),
      doneChunk(),
    ]
    let agent = makeAgent(chunks: toolCallChunks, tools: [SleepyAgentTool()])
    let ts = await agent.prompt("test", log: testLogger)
    let drain = Task { for await _ in ts.events {} }
    // Give the loop a beat to enter the tool watch task before aborting.
    try await Task.sleep(for: .milliseconds(50))
    agent.abort()
    let result = try await ts.result.value
    await drain.value
    #expect(result.outcome == .interrupted)
  }

  /// Aborting between prompts is intentionally a no-op. The next `prompt()`
  /// clears the notifier and runs to completion.
  @Test func abortBetweenPromptsDoesNotLeak() async throws {
    let chunks = [
      sseChunk(#"{"id":"1","choices":[{"index":0,"delta":{"content":"ok"}}]}"#),
      doneChunk(),
    ]
    let agent = makeAgent(chunks: chunks)
    agent.abort()  // fired with no in-flight turn
    let ts = await agent.prompt("test", log: testLogger)
    Task { for await _ in ts.events {} }
    let result = try await ts.result.value
    #expect(result.outcome == .completed)
  }

  // MARK: - messages(since:)

  @Test func messagesSinceReturnsTailSlice() async throws {
    let chunks = [
      sseChunk(#"{"id":"1","choices":[{"index":0,"delta":{"content":"ok"}}]}"#),
      doneChunk(),
    ]
    let agent = makeAgent(chunks: chunks)
    let ts = await agent.prompt("one", log: testLogger)
    Task { for await _ in ts.events {} }
    _ = try await ts.result.value
    let ts2 = await agent.prompt("two", log: testLogger)
    Task { for await _ in ts2.events {} }
    _ = try await ts2.result.value

    // messages: system, user:"one", assistant:"ok", user:"two", assistant:"ok"
    let tail = await agent.messages(since: 3)
    #expect(tail.count == 2)
    #expect(tail.first?.role == .user)
    #expect(tail.first?.content == "two")
  }

  @Test func messagesSinceAtCountReturnsEmpty() async throws {
    let chunks = [
      sseChunk(#"{"id":"1","choices":[{"index":0,"delta":{"content":"ok"}}]}"#),
      doneChunk(),
    ]
    let agent = makeAgent(chunks: chunks)
    let ts = await agent.prompt("hello", log: testLogger)
    Task { for await _ in ts.events {} }
    _ = try await ts.result.value

    let total = await agent.messages.count
    let empty = await agent.messages(since: total)
    #expect(empty.isEmpty)
  }

  @Test func messagesSinceZeroReturnsAll() async throws {
    let agent = makeAgent(chunks: [])
    let total = await agent.messages.count  // just system
    let all = await agent.messages(since: 0)
    #expect(all.count == total)
  }

  @Test func messagesSinceNegativeClampedToZero() async throws {
    let agent = makeAgent(chunks: [])
    let total = await agent.messages.count
    let all = await agent.messages(since: -5)
    #expect(all.count == total)
  }

  // MARK: - System prompt auto-injection

  /// When the caller provides a non-empty `systemPrompt` but no system
  /// message in `initialMessages`, the agent injects one at construction
  /// time so embedders don't have to know about the wire shape.
  @Test func autoInjectsSystemPromptAtHead() async throws {
    let chunks = [
      sseChunk(#"{"id":"1","choices":[{"index":0,"delta":{"content":"hi"}}]}"#),
      doneChunk(),
    ]
    let agent = makeAgent(chunks: chunks)  // systemPrompt = "You are a test agent."
    let messages = await agent.messages
    #expect(messages.count == 1)
    #expect(messages.first?.role == .system)
    #expect(messages.first?.content == "You are a test agent.")
  }

  /// If the caller already supplied a system message in `initialMessages`,
  /// the agent must not inject a second one — preserves backward
  /// compatibility with callers (like the CLI) that bake the system
  /// message in themselves.
  @Test func doesNotDuplicateExistingSystemMessage() async throws {
    let transport = FakeClientTransport(statusCode: 200, responseBodyChunks: [])
    let client = Client(serverURL: URL(string: "http://test")!, transport: transport)
    let agent = ScribeAgent(
      client: client,
      model: "test",
      systemPrompt: "ignored, already present",
      tools: [],
      initialMessages: [
        ScribeMessage(role: .system, content: "pre-baked"),
        ScribeMessage(role: .user, content: "first"),
      ],
      workingDirectory: ScribeFilePath("/tmp"),
    reasoningEnabled: nil
    )
    let messages = await agent.messages
    #expect(messages.count == 2)
    #expect(messages[0].role == .system)
    #expect(messages[0].content == "pre-baked")
    #expect(messages[1].role == .user)
  }

  // MARK: - ScribeMessage prompt overload

  @Test func promptAcceptsScribeMessageArray() async throws {
    let chunks = [
      sseChunk(#"{"id":"1","choices":[{"index":0,"delta":{"content":"ack"}}]}"#),
      doneChunk(),
    ]
    let agent = makeAgent(chunks: chunks)
    let userMsg = ScribeMessage(role: .user, content: "hello")
    let ts = await agent.prompt([userMsg], log: testLogger)
    Task { for await _ in ts.events {} }
    let result = try await ts.result.value
    #expect(result.outcome == .completed)
    #expect(result.messages.last?.role == .assistant)
    #expect(result.messages.last?.content == "ack")
  }

  // MARK: - Custom ToolExecutor

  /// A fake tool that records calls — `ToolExecutor` should never be
  /// invoked for it because the test installs a custom executor that
  /// short-circuits all tool calls.
  private struct UnreachableTool: ScribeTool {
    static var name: String { "unreachable" }
    static var description: String { "Built-in tool that should never run." }
    static var parameters: [ScribeToolParameter] { [] }
    static var promptHint: String? { nil }
    struct Result: Encodable { let ok = false }
    func run(arguments: String, workingDirectory: ScribeFilePath) async throws -> Encodable {
      Issue.record("Built-in tool ran despite a custom ToolExecutor being installed.")
      return Result()
    }
  }

  /// Custom `ToolExecutor` that records every invocation and returns a
  /// canned JSON string. Demonstrates the HITL / sandbox-forwarder use
  /// case described in §1 issue 3 of the review.
  private final class RecordingExecutor: ToolExecutor {
    let invocations = Mutex<[ToolInvocation]>([])
    let canned: String

    init(canned: String = #"{"ok":true,"from":"recorder"}"#) {
      self.canned = canned
    }

    func execute(
      _ invocation: ToolInvocation,
      workingDirectory: ScribeFilePath,
      abort: any AbortObserver
    ) async throws -> String {
      invocations.withLock { $0.append(invocation) }
      return canned
    }
  }

  @Test func customToolExecutorReceivesInvocations() async throws {
    let toolChunks = [
      sseChunk(
        #"{"id":"1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"unreachable","arguments":"{\"k\":1}"}}]}}]}"#
      ),
      doneChunk(),
    ]
    let replyChunks = [
      sseChunk(#"{"id":"2","choices":[{"index":0,"delta":{"content":"all done"}}]}"#),
      doneChunk(),
    ]
    let transport = FakeClientTransport(
      statusCode: 200,
      responseBodyChunksForCall: [toolChunks, replyChunks]
    )
    let client = Client(serverURL: URL(string: "http://test")!, transport: transport)
    let recorder = RecordingExecutor()
    let agent = ScribeAgent(
      client: client,
      model: "test",
      systemPrompt: "system",
      tools: [UnreachableTool()],
      toolExecutor: recorder,
      initialMessages: [],
      workingDirectory: ScribeFilePath("/tmp"),
      reasoningEnabled: nil
    )
    let ts = await agent.prompt("call the tool", log: testLogger)
    Task { for await _ in ts.events {} }
    let task = ts.result
    let result = try await task.value
    #expect(result.outcome == .completed)
    let recorded = recorder.invocations.withLock { $0 }
    #expect(recorded.count == 1)
    #expect(recorded.first?.name == "unreachable")
    #expect(recorded.first?.id == "c1")
    #expect(recorded.first?.arguments == #"{"k":1}"#)
    // The tool message in the conversation should carry the canned output,
    // confirming the assistant saw the executor's response (not the
    // unreachable built-in).
    let toolMessage = result.messages.first { $0.role == .tool }
    #expect(stringContent(toolMessage) == recorder.canned)
  }
}

private func stringContent(_ msg: ScribeMessage?) -> String? {
  guard let msg else { return nil }
  if let parts = msg.contentParts, !parts.isEmpty {
    if case .text(let text) = parts.first { return text }
    return nil
  }
  return msg.content
}
