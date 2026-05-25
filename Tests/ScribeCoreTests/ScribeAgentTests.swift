import SystemPackage
import Foundation
import HTTPTypes
import Logging
import OpenAPIRuntime
import ScribeCore
import ScribeLLM
import Synchronization
import Testing


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


private struct FakeTool: ScribeTool {
  static var name: String { "fake_tool" }
  static var description: String { "A fake tool for testing." }
  static var parameters: [ScribeToolParameter] { [] }
  static var promptHint: String? { nil }
  struct Result: Encodable { let ok = true }
  func run(arguments: String, workingDirectory: FilePath, logger: Logger) async throws -> Encodable {
    _ = logger
    return Result()
  }
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
  func run(arguments: String, workingDirectory: FilePath, logger: Logger) async throws -> Encodable {
    _ = logger
    try await Task.sleep(for: .seconds(60))
    return Result()
  }
}


private func sseChunk(_ json: String) -> HTTPBody.ByteChunk {
  ArraySlice("data: \(json)\n\n".utf8)
}
private func doneChunk() -> HTTPBody.ByteChunk {
  ArraySlice("data: [DONE]\n\n".utf8)
}
private func errorBody(_ message: String) -> HTTPBody.ByteChunk {
  ArraySlice(#"{"error":{"message":"\#(message)"}}"#.utf8)
}


private let testLogger = Logger(label: "test")

/// Default history every agent test runs against: just a system message.
/// Mirrors the typical embedder shape — caller owns the conversation
/// store, the agent is a pure verb.
private let defaultHistory: [ScribeMessage] = [
  ScribeMessage(role: .system, content: "You are a test agent.")
]

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
    tools: tools,
    workingDirectory: FilePath("/tmp"),
    reasoningEnabled: nil,
    logger: testLogger
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
    tools: tools,
    workingDirectory: FilePath("/tmp"),
    reasoningEnabled: nil,
    logger: testLogger
  )
}


@Suite
struct ScribeAgentTests {


  @Test func runCompletesWithAnswerText() async throws {
    let chunks = [
      sseChunk(#"{"id":"1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"done"}}]}"#),
      doneChunk(),
    ]
    let agent = makeAgent(chunks: chunks)
    let ts = agent.run("hello", history: defaultHistory)
    Task { for await _ in ts.events {} }
    let result = try await ts.result.value
    #expect(result.outcome == .completed)
  }

  @Test func runRespectsMaxToolRounds() async throws {
    let chunks = [
      sseChunk(
        #"{"id":"1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"fake_tool","arguments":"{}"}}]}}]}"#
      ),
      doneChunk(),
    ]
    let agent = makeAgent(chunks: chunks, tools: [FakeTool()])
    let options = AgentRunOptions(maxToolRounds: 1)
    let ts = agent.run("test", history: defaultHistory, options: options)
    Task { for await _ in ts.events {} }
    let result = try await ts.result.value
    #expect(result.outcome == .toolRoundLimit(rounds: 1))
  }


  @Test func runYieldsAssistantTextEvents() async throws {
    let chunks = [
      sseChunk(#"{"id":"1","choices":[{"index":0,"delta":{"content":"hello"}}]}"#),
      sseChunk(#"{"id":"1","choices":[{"index":0,"delta":{"content":" world"}}]}"#),
      doneChunk(),
    ]
    let agent = makeAgent(chunks: chunks)
    let ts = agent.run("test", history: defaultHistory)
    var texts: [String] = []
    for await event in ts.events {
      if case .output(.text(_, let text)) = event { texts.append(text) }
    }
    let result = try await ts.result.value
    #expect(texts == ["hello", " world"])
    #expect(result.outcome == .completed)
  }

  @Test func runYieldsToolInvocationEvents() async throws {
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
    let ts = agent.run("test", history: defaultHistory)
    var events: [AgentEvent] = []
    for await event in ts.events { events.append(event) }
    let result = try await ts.result.value
    #expect(result.outcome == .completed)
    let hasInvocation = events.contains(where: {
      if case .tool(.invocation(let name, _, _)) = $0, name == "fake_tool" { return true }
      return false
    })
    #expect(hasInvocation)
  }

  @Test func runYieldsUsageEvent() async throws {
    let chunks = [
      sseChunk(#"{"id":"1","choices":[{"index":0,"delta":{"content":"x"}}]}"#),
      sseChunk(#"{"id":"1","choices":[],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}"#),
      doneChunk(),
    ]
    let agent = makeAgent(chunks: chunks)
    let ts = agent.run("test", history: defaultHistory)
    var events: [AgentEvent] = []
    for await event in ts.events { events.append(event) }
    _ = try await ts.result.value
    let hasUsage = events.contains(where: {
      if case .lifecycle(.usage(let u, _)) = $0, u.promptTokens == 10, u.completionTokens == 5, u.totalTokens == 15 { return true }
      return false
    })
    #expect(hasUsage)
  }


  @Test func runResultNewMessagesContainsPromptAndAssistant() async throws {
    let chunks = [
      sseChunk(#"{"id":"1","choices":[{"index":0,"delta":{"content":"reply"}}]}"#),
      doneChunk(),
    ]
    let agent = makeAgent(chunks: chunks)
    let ts = agent.run("hello", history: defaultHistory)
    Task { for await _ in ts.events {} }
    let result = try await ts.result.value
    // newMessages excludes pre-turn history (system) and contains only
    // the prompt user message + the assistant reply produced by the turn.
    #expect(result.newMessages.count == 2)
    #expect(result.newMessages[0].role == .user)
    #expect(result.newMessages[0].content == "hello")
    #expect(result.newMessages[1].role == .assistant)
    #expect(result.newMessages[1].content == "reply")
  }

  @Test func runResultNewMessagesAfterToolRound() async throws {
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
    let ts = agent.run("test", history: defaultHistory)
    Task { for await _ in ts.events {} }
    let result = try await ts.result.value
    #expect(result.outcome == .completed)
    // newMessages = user(prompt) + assistant(tool-calling) + tool(result) + assistant(done).
    // The pre-turn system message is NOT included.
    #expect(result.newMessages.count == 4)
    #expect(result.newMessages[0].role == .user)
    #expect(result.newMessages[1].role == .assistant)
    #expect(result.newMessages[2].role == .tool)
    #expect(result.newMessages[2].toolCallId == "c1")
    #expect(result.newMessages[3].role == .assistant)
    #expect(result.newMessages[3].content == "done")
  }


  @Test func runPropagatesHTTPError() async {
    let agent = makeAgent(statusCode: 500, chunks: [errorBody("boom")])
    let ts = agent.run("test", history: defaultHistory)
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

  @Test func runStreamFinishesOnError() async {
    let agent = makeAgent(statusCode: 500, chunks: [errorBody("boom")])
    let ts = agent.run("test", history: defaultHistory)
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


  /// Verify `agent.abort()` interrupts an in-flight turn. We can't pre-set
  /// abort before `run()` because the agent clears its private notifier
  /// at the top of each turn (so a stray Ctrl+C between turns can't
  /// bleed into the next one). Instead we start a tool call against a
  /// long-sleeping tool so the loop is stuck in the watch task, then call
  /// `abort()` to wake it.
  @Test func runAbortReturnsInterrupted() async throws {
    let toolCallChunks = [
      sseChunk(
        #"{"id":"1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"sleepy","arguments":"{}"}}]}}]}"#
      ),
      doneChunk(),
    ]
    let agent = makeAgent(chunks: toolCallChunks, tools: [SleepyAgentTool()])
    let ts = agent.run("test", history: defaultHistory)
    let drain = Task { for await _ in ts.events {} }
    // Give the loop a beat to enter the tool watch task before aborting.
    try await Task.sleep(for: .milliseconds(50))
    agent.abort()
    let result = try await ts.result.value
    await drain.value
    #expect(result.outcome == .interrupted)
  }

  /// Aborting between turns is intentionally a no-op. The next `run()`
  /// clears the notifier and runs to completion.
  @Test func abortBetweenRunsDoesNotLeak() async throws {
    let chunks = [
      sseChunk(#"{"id":"1","choices":[{"index":0,"delta":{"content":"ok"}}]}"#),
      doneChunk(),
    ]
    let agent = makeAgent(chunks: chunks)
    agent.abort()  // fired with no in-flight turn
    let ts = agent.run("test", history: defaultHistory)
    Task { for await _ in ts.events {} }
    let result = try await ts.result.value
    #expect(result.outcome == .completed)
  }


  @Test func runAcceptsScribeMessageArray() async throws {
    let chunks = [
      sseChunk(#"{"id":"1","choices":[{"index":0,"delta":{"content":"ack"}}]}"#),
      doneChunk(),
    ]
    let agent = makeAgent(chunks: chunks)
    let userMsg = ScribeMessage(role: .user, content: "hello")
    let ts = agent.run([userMsg], history: defaultHistory)
    Task { for await _ in ts.events {} }
    let result = try await ts.result.value
    #expect(result.outcome == .completed)
    #expect(result.newMessages.last?.role == .assistant)
    #expect(result.newMessages.last?.content == "ack")
  }


  /// A fake tool that records calls — `ToolExecutor` should never be
  /// invoked for it because the test installs a custom executor that
  /// short-circuits all tool calls.
  private struct UnreachableTool: ScribeTool {
    static var name: String { "unreachable" }
    static var description: String { "Built-in tool that should never run." }
    static var parameters: [ScribeToolParameter] { [] }
    static var promptHint: String? { nil }
    struct Result: Encodable { let ok = false }
    func run(arguments: String, workingDirectory: FilePath, logger: Logger) async throws -> Encodable {
      _ = logger
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
      workingDirectory: FilePath,
      logger: Logger,
      abort: any AbortObserver
    ) async throws -> ToolResult {
      invocations.withLock { $0.append(invocation) }
      return ToolResult(text: canned)
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
      tools: [UnreachableTool()],
      toolExecutor: recorder,
      workingDirectory: FilePath("/tmp"),
      reasoningEnabled: nil,
      logger: testLogger
    )
    let history: [ScribeMessage] = [ScribeMessage(role: .system, content: "system")]
    let ts = agent.run("call the tool", history: history)
    Task { for await _ in ts.events {} }
    let task = ts.result
    let result = try await task.value
    #expect(result.outcome == .completed)
    let recorded = recorder.invocations.withLock { $0 }
    #expect(recorded.count == 1)
    #expect(recorded.first?.name == "unreachable")
    #expect(recorded.first?.id == "c1")
    #expect(recorded.first?.arguments == #"{"k":1}"#)
    // The tool message in newMessages should carry the canned output,
    // confirming the assistant saw the executor's response (not the
    // unreachable built-in).
    let toolMessage = result.newMessages.first { $0.role == .tool }
    #expect(stringContent(toolMessage) == recorder.canned)
  }
}

private func stringContent(_ msg: ScribeMessage?) -> String? {
  guard let msg else { return nil }
  return msg.content.isEmpty ? nil : msg.content
}
