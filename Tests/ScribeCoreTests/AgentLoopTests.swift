import Foundation
import HTTPTypes
import Logging
import OpenAPIRuntime
import ScribeLLM
import Synchronization
import SystemPackage
import Testing

@testable import ScribeCore

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

private final class HangingClientTransport: ClientTransport, Sendable {
  func send(
    _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
  ) async throws -> (HTTPResponse, HTTPBody?) {

    try await Task.sleep(for: .seconds(3600))
    return (HTTPResponse(status: .init(code: 200)), nil)
  }
}

private final class VariedStatusTransport: ClientTransport, Sendable {
  private let callPlan: [(Int, [HTTPBody.ByteChunk])]
  private let state: Mutex<Int> = Mutex(0)

  init(callPlan: [(Int, [HTTPBody.ByteChunk])]) {
    self.callPlan = callPlan
  }

  func send(
    _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
  ) async throws -> (HTTPResponse, HTTPBody?) {
    let (statusCode, chunks) = state.withLock { idx -> (Int, [HTTPBody.ByteChunk]) in
      let i = min(idx, callPlan.count - 1)
      idx += 1
      return callPlan[i]
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

private struct InterruptedTool: ScribeTool {
  static var name: String { "interrupted_tool" }
  static var description: String { "Throws AgentTurnInterruptedError." }
  static var parameters: [ScribeToolParameter] { [] }
  static var promptHint: String? { nil }
  struct Result: Encodable { let ok = true }
  func run(arguments: String, workingDirectory: FilePath, logger: Logger) async throws -> Encodable {
    _ = logger
    throw AgentTurnInterruptedError()
  }
}

private func sseChunk(_ json: String) -> HTTPBody.ByteChunk {
  ArraySlice("data: \(json)\n\n".utf8)
}

private func doneChunk() -> HTTPBody.ByteChunk {
  ArraySlice("data: [DONE]\n\n".utf8)
}

private let testLogger = Logger(label: "test.agentloop")

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

private func makeConfig(
  statusCode: Int = 200,
  chunks: [HTTPBody.ByteChunk],
  model: String = "test-model",
  tools: [any ScribeTool] = [],
  temperature: Double = 0,
  maxToolRounds: Int = .max,
  hooks: AgentLoopHooks = .default
) -> AgentLoopConfig {
  let transport = FakeClientTransport(statusCode: statusCode, responseBodyChunks: chunks)
  let client = Client(serverURL: URL(string: "http://test")!, transport: transport)
  let registry = ToolRegistry(tools: tools, logger: testLogger)
  return AgentLoopConfig(
    model: model,
    client: client,
    toolExecutor: registry,
    chatTools: registry.chatTools,
    temperature: temperature,
    maxToolRounds: maxToolRounds, workingDirectory: FilePath("/tmp"),
    reasoningEnabled: true,
    hooks: hooks
  )
}

private func runLoop(
  prompt: String,
  context: AgentContext = AgentContext(messages: []),
  config: AgentLoopConfig,
  abortNotifier: AbortNotifier = AbortNotifier()
) async throws -> (messages: [Components.Schemas.ChatMessage], termination: TurnOutcome) {
  let userMsg = Components.Schemas.ChatMessage(role: .user, content: .case1(prompt))
  return try await runAgentLoop(
    promptMessages: [userMsg],
    context: context,
    config: config,
    emit: { _ in },
    logger: testLogger,
    abortObserver: abortNotifier
  )
}

private func runLoop(
  prompt: String,
  context: AgentContext = AgentContext(messages: []),
  config: AgentLoopConfig,
  countingAbortObserver: CountingAbortObserver = CountingAbortObserver(triggerAt: 1)
) async throws -> (messages: [Components.Schemas.ChatMessage], termination: TurnOutcome) {
  let userMsg = Components.Schemas.ChatMessage(role: .user, content: .case1(prompt))
  return try await runAgentLoop(
    promptMessages: [userMsg],
    context: context,
    config: config,
    emit: { _ in },
    logger: testLogger,
    abortObserver: countingAbortObserver
  )
}

private func stringContent(_ msg: Components.Schemas.ChatMessage) -> String? {
  guard let content = msg.content else { return nil }
  switch content {
  case .case1(let text): return text
  case .case2: return nil
  }
}

private func expectTermination(_ actual: TurnOutcome, _ expected: TurnOutcome) {
  switch (actual, expected) {
  case (.completed, .completed): return
  case (.interrupted, .interrupted): return
  case (.toolRoundLimit(let a), .toolRoundLimit(let b)) where a == b: return
  default:
    #expect(Bool(false), Comment(rawValue: "Expected \(expected), got \(actual)"))
  }
}

@Suite
struct AgentLoopTests {

  @Test func completesWithAssistantReply() async throws {
    let chunks = [
      sseChunk(#"{"id":"1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"reply"}}]}"#),
      doneChunk(),
    ]
    let (messages, termination) = try await runLoop(
      prompt: "hello", config: makeConfig(chunks: chunks), abortNotifier: AbortNotifier())
    expectTermination(termination, .completed)
    #expect(messages.count == 2)
    #expect(messages[0].role == .user)
    #expect(stringContent(messages[0]) == "hello")
    #expect(messages[1].role == .assistant)
    #expect(stringContent(messages[1]) == "reply")
  }

  @Test func completesWithEmptyAssistantText() async throws {

    let chunks = [
      sseChunk(#"{"id":"1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{}}]}"#),
      doneChunk(),
    ]
    let (messages, termination) = try await runLoop(
      prompt: "hello", config: makeConfig(chunks: chunks), abortNotifier: AbortNotifier())
    expectTermination(termination, .completed)
    #expect(messages.count == 2)
    #expect(messages[1].role == .assistant)
    #expect(messages[1].content == nil)
  }

  @Test func toolRoundLimit() async throws {
    let chunks = [
      sseChunk(
        #"{"id":"1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"fake_tool","arguments":"{}"}}]}}]}"#
      ),
      doneChunk(),
    ]
    let config = makeConfig(chunks: chunks, tools: [FakeTool()], maxToolRounds: 1)
    let (messages, termination) = try await runLoop(
      prompt: "test", config: config, abortNotifier: AbortNotifier())
    expectTermination(termination, .toolRoundLimit(rounds: 1))

    #expect(messages.count == 1)
    #expect(messages[0].role == .user)
  }

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
    let registry = ToolRegistry(tools: [FakeTool()], logger: toolRunnerTestLogger)
    let config = AgentLoopConfig(
      model: "test-model",
      client: client,
      toolExecutor: registry,
      chatTools: registry.chatTools,
      temperature: 0,
      maxToolRounds: .max, workingDirectory: FilePath("/tmp"),
      reasoningEnabled: true,
      hooks: .default
    )
    let (messages, termination) = try await runLoop(
      prompt: "test", config: config, abortNotifier: AbortNotifier())
    expectTermination(termination, .completed)

    #expect(messages.count == 4)
    #expect(messages[0].role == .user)
    #expect(messages[1].role == .assistant)
    #expect(messages[2].role == .tool)
    #expect(messages[2].toolCallId == "c1")
    #expect(messages[3].role == .assistant)
    #expect(stringContent(messages[3]) == "done")
  }

  @Test func abortBeforeHTTP() async throws {
    let chunks = [
      sseChunk(#"{"id":"1","choices":[{"index":0,"delta":{"content":"hello"}}]}"#),
      doneChunk(),
    ]
    let notifier = AbortNotifier()
    notifier.request()
    let (messages, termination) = try await runLoop(
      prompt: "test",
      config: makeConfig(chunks: chunks),
      abortNotifier: notifier
    )
    expectTermination(termination, .interrupted)

    #expect(messages.count == 1)
    #expect(messages[0].role == .user)
  }

  @Test func abortPostStreamPreTools() async throws {
    let chunks = [
      sseChunk(
        #"{"id":"1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"fake_tool","arguments":"{}"}}]}}]}"#
      ),
      doneChunk(),
    ]
    let (messages, termination) = try await runLoop(
      prompt: "test",
      config: makeConfig(chunks: chunks, tools: [FakeTool()]),
      countingAbortObserver: CountingAbortObserver(triggerAt: 2)
    )
    expectTermination(termination, .interrupted)

    #expect(messages.count == 1)
    #expect(messages[0].role == .user)
  }

  @Test func abortPreTool() async throws {
    let chunks = [
      sseChunk(
        #"{"id":"1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"fake_tool","arguments":"{}"}}]}}]}"#
      ),
      doneChunk(),
    ]
    let (messages, termination) = try await runLoop(
      prompt: "test",
      config: makeConfig(chunks: chunks, tools: [FakeTool()]),
      countingAbortObserver: CountingAbortObserver(triggerAt: 3)
    )
    expectTermination(termination, .interrupted)
    #expect(messages.count == 1)
    #expect(messages[0].role == .user)
  }

  @Test func abortDuringToolExecutionViaBeforeStart() async throws {
    let chunks = [
      sseChunk(
        #"{"id":"1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"fake_tool","arguments":"{}"}}]}}]}"#
      ),
      doneChunk(),
    ]
    let (messages, termination) = try await runLoop(
      prompt: "test",
      config: makeConfig(chunks: chunks, tools: [FakeTool()]),
      countingAbortObserver: CountingAbortObserver(triggerAt: 4)
    )
    expectTermination(termination, .interrupted)
    #expect(messages.count == 1)
  }

  @Test func abortInterruptsHungHTTPRequest() async throws {
    let transport = HangingClientTransport()
    let client = Client(serverURL: URL(string: "http://test")!, transport: transport)
    let registry = ToolRegistry(tools: [], logger: testLogger)
    let config = AgentLoopConfig(
      model: "test-model",
      client: client,
      toolExecutor: registry,
      chatTools: registry.chatTools,
      temperature: 0,
      maxToolRounds: .max,
      workingDirectory: FilePath("/tmp"),
      reasoningEnabled: nil,
      hooks: .default
    )
    let notifier = AbortNotifier()

    let start = ContinuousClock.now
    async let loopResult = runLoop(prompt: "test", config: config, abortNotifier: notifier)

    try await Task.sleep(for: .milliseconds(50))
    notifier.request()

    let (_, termination) = try await loopResult
    let elapsed = start.duration(to: .now)
    expectTermination(termination, .interrupted)

    #expect(
      elapsed < .seconds(1),
      "abort should interrupt a hung HTTP request promptly; took \(elapsed)"
    )
  }

  @Test func unknownToolReturnsJSONError() async throws {
    try await withTimeout(seconds: 5) {

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
      let registry = ToolRegistry(tools: [FakeTool()], logger: toolRunnerTestLogger)
      let config = AgentLoopConfig(
        model: "test-model",
        client: client,
        toolExecutor: registry,
        chatTools: registry.chatTools,
        temperature: 0,
        maxToolRounds: .max, workingDirectory: FilePath("/tmp"),
        reasoningEnabled: true,
        hooks: .default
      )
      let (messages, termination) = try await runLoop(
        prompt: "test",
        config: config, abortNotifier: AbortNotifier()
      )
      expectTermination(termination, .completed)

      let toolMessages = messages.filter { $0.role == .tool }
      #expect(toolMessages.count >= 1)
      if let toolMsg = toolMessages.first {
        #expect(toolMsg.toolCallId == "c1")
        #expect(stringContent(toolMsg)?.contains("unknown tool") == true)
      }
    }
  }

  @Test func http404Error() async throws {
    let config = makeConfig(statusCode: 404, chunks: [errorBody("not found")])
    do {
      _ = try await runLoop(prompt: "test", config: config, abortNotifier: AbortNotifier())
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
      _ = try await runLoop(prompt: "test", config: config, abortNotifier: AbortNotifier())
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
      _ = try await runLoop(prompt: "test", config: config, abortNotifier: AbortNotifier())
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

      let longMessage = String(repeating: "x", count: 600)
      let config = makeConfig(statusCode: 500, chunks: [errorBody(longMessage)])
      do {
        _ = try await runLoop(prompt: "test", config: config, abortNotifier: AbortNotifier())
        #expect(Bool(false), "expected error")
      } catch let error as ScribeError {
        guard case .apiHTTPError(let code, let detail, _) = error else {
          #expect(Bool(false))
          return
        }
        #expect(code == 500)

        #expect(detail.contains(longMessage))
      }
    }
  }

  @Test func usageWithoutCompletionTokens() async throws {
    let chunks = [
      sseChunk(#"{"id":"1","choices":[{"index":0,"delta":{"content":"x"}}]}"#),
      sseChunk(#"{"id":"1","choices":[],"usage":{"prompt_tokens":10,"total_tokens":10}}"#),
      doneChunk(),
    ]
    let events = Mutex<[AgentEvent]>([])
    let userMsg = Components.Schemas.ChatMessage(role: .user, content: .case1("test"))
    let (_, termination) = try await runAgentLoop(
      promptMessages: [userMsg],
      context: AgentContext(messages: []),
      config: makeConfig(chunks: chunks),
      emit: { event in events.withLock { $0.append(event) } },
      logger: testLogger,
      abortObserver: AbortNotifier()
    )
    expectTermination(termination, .completed)
    let captured = events.withLock { $0 }
    let usageEvents = captured.compactMap { (e: AgentEvent) -> (ScribeUsage, Double?)? in
      if case .lifecycle(.usage(let u, let tps)) = e { return (u, tps) }
      return nil
    }
    #expect(usageEvents.count == 1)
    #expect(usageEvents[0].0.promptTokens == 10)
    #expect(usageEvents[0].0.completionTokens == nil)
    #expect(usageEvents[0].1 == nil)
  }

  @Test func reasoningContentIncludedInAssistantMessage() async throws {
    let chunks = [
      sseChunk(
        #"{"id":"1","choices":[{"index":0,"delta":{"reasoning_content":"Let me think...","content":"answer"}}]}"#),
      doneChunk(),
    ]
    let (messages, termination) = try await runLoop(
      prompt: "test", config: makeConfig(chunks: chunks), abortNotifier: AbortNotifier())
    expectTermination(termination, .completed)
    #expect(messages.count == 2)
    #expect(messages[1].role == .assistant)
    #expect(stringContent(messages[1]) == "answer")
    #expect(messages[1].reasoningContent == "Let me think...")
  }

  @Test func reasoningOnlyAssistantMessageOmitsEmptyContent() async throws {
    let chunks = [
      sseChunk(
        #"{"id":"1","choices":[{"index":0,"delta":{"reasoning_content":"Let me think..."}}]}"#),
      doneChunk(),
    ]
    let (messages, termination) = try await runLoop(
      prompt: "test", config: makeConfig(chunks: chunks), abortNotifier: AbortNotifier())
    expectTermination(termination, .completed)
    #expect(messages.count == 2)
    #expect(messages[1].role == .assistant)
    #expect(messages[1].content == nil)
    #expect(messages[1].toolCalls == nil)
    #expect(messages[1].reasoningContent == "Let me think...")
  }

  @Test func emptyPromptMessagesWithInitialContext() async throws {
    let chunks = [
      sseChunk(#"{"id":"1","choices":[{"index":0,"delta":{"content":"reply"}}]}"#),
      doneChunk(),
    ]
    let initialMessages: [Components.Schemas.ChatMessage] = [
      .init(role: .system, content: .case1("System prompt")),
      .init(role: .user, content: .case1("previous question")),
      .init(role: .assistant, content: .case1("previous answer")),
    ]
    let context = AgentContext(messages: initialMessages)
    let (messages, termination) = try await runAgentLoop(
      promptMessages: [],
      context: context,
      config: makeConfig(chunks: chunks),
      emit: { _ in },
      logger: testLogger,
      abortObserver: AbortNotifier()
    )
    expectTermination(termination, .completed)

    #expect(messages.count == 1)
    #expect(messages[0].role == .assistant)
    #expect(stringContent(messages[0]) == "reply")
  }

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
    let registry = ToolRegistry(tools: [FakeTool()], logger: toolRunnerTestLogger)
    let config = AgentLoopConfig(
      model: "test-model",
      client: client,
      toolExecutor: registry,
      chatTools: registry.chatTools,
      temperature: 0,
      maxToolRounds: .max, workingDirectory: FilePath("/tmp"),
      reasoningEnabled: true,
      hooks: .default
    )
    let (messages, termination) = try await runLoop(
      prompt: "test", config: config, abortNotifier: AbortNotifier())
    expectTermination(termination, .completed)

    #expect(messages.count == 5)
    #expect(messages[0].role == .user)
    #expect(messages[1].role == .assistant)
    #expect(messages[2].role == .tool)
    #expect(messages[2].toolCallId == "c1")
    #expect(messages[3].role == .tool)
    #expect(messages[3].toolCallId == "c2")
    #expect(messages[4].role == .assistant)
    #expect(stringContent(messages[4]) == "all done")
  }

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
    let registry = ToolRegistry(tools: [InterruptedTool()], logger: toolRunnerTestLogger)
    let config = AgentLoopConfig(
      model: "test-model",
      client: client,
      toolExecutor: registry,
      chatTools: registry.chatTools,
      temperature: 0,
      maxToolRounds: .max, workingDirectory: FilePath("/tmp"),
      reasoningEnabled: true,
      hooks: .default
    )
    let (messages, termination) = try await runLoop(
      prompt: "test", config: config, abortNotifier: AbortNotifier())

    expectTermination(termination, .completed)
    #expect(messages.count == 4)
    #expect(messages[2].role == .tool)
    #expect(stringContent(messages[2])?.contains("ok") == true)
  }

  private struct AttachingTool: ScribeTool {
    static var name: String { "attaching_tool" }
    static var description: String { "Returns an image attachment for testing." }
    static var parameters: [ScribeToolParameter] { [] }
    static var promptHint: String? { nil }
    struct Result: Encodable, AttachableToolResult {
      let ok = true
      var toolAttachments: [ToolAttachment] {
        [ToolAttachment(mimeType: "image/png", base64: "AAAA", filename: "tiny.png", sourcePath: nil)]
      }
    }
    func run(arguments: String, workingDirectory: FilePath, logger: Logger) async throws -> Encodable {
      _ = logger
      return Result()
    }
  }

  @Test func contextOverflowRecoversByRollingBackAttachments() async throws {

    let toolChunks = [
      sseChunk(
        #"{"id":"1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"attaching_tool","arguments":"{}"}}]}}]}"#
      ),
      doneChunk(),
    ]

    let overflowBody: HTTPBody.ByteChunk = ArraySlice(
      #"{"error":{"message":"The prompt is too long: 798932, model maximum context length: 262143"}}"#
        .utf8)

    let recoveryChunks = [
      sseChunk(#"{"id":"3","choices":[{"index":0,"delta":{"content":"done"}}]}"#),
      doneChunk(),
    ]
    let transport = VariedStatusTransport(callPlan: [
      (200, toolChunks),
      (400, [overflowBody]),
      (200, recoveryChunks),
    ])
    let client = Client(serverURL: URL(string: "http://test")!, transport: transport)
    let registry = ToolRegistry(tools: [AttachingTool()], logger: testLogger)
    let config = AgentLoopConfig(
      model: "test-model",
      client: client,
      toolExecutor: registry,
      chatTools: registry.chatTools,
      temperature: 0,
      maxToolRounds: .max,
      workingDirectory: FilePath("/tmp"),
      reasoningEnabled: nil,
      hooks: .default
    )
    let events = Mutex<[AgentEvent]>([])
    let userMsg = Components.Schemas.ChatMessage(role: .user, content: .case1("read image"))
    let (messages, termination) = try await runAgentLoop(
      promptMessages: [userMsg],
      context: AgentContext(messages: []),
      config: config,
      emit: { e in events.withLock { $0.append(e) } },
      logger: testLogger,
      abortObserver: AbortNotifier()
    )
    expectTermination(termination, .completed)

    let recovered = events.withLock { $0 }.compactMap { e -> String? in
      if case .lifecycle(.recovered(let reason)) = e { return reason }
      return nil
    }
    #expect(recovered.count == 1)
    #expect(recovered.first?.contains("attachment") == true)

    let attachmentSurvivors = messages.filter { msg in
      guard msg.role == .user, case .case2 = msg.content else { return false }
      return true
    }
    #expect(attachmentSurvivors.isEmpty)

    let toolMsg = messages.first { $0.role == .tool }
    #expect(toolMsg?.toolCallId == "c1")
    #expect(stringContent(toolMsg!)?.contains("exceeded model context") == true)

    #expect(messages.last?.role == .assistant)
    #expect(stringContent(messages.last!) == "done")
  }

  @Test func contextOverflowRecoveryRunsAtMostOncePerTurn() async throws {
    let toolChunks = [
      sseChunk(
        #"{"id":"1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"attaching_tool","arguments":"{}"}}]}}]}"#
      ),
      doneChunk(),
    ]
    let overflowBody: HTTPBody.ByteChunk = ArraySlice(
      #"{"error":{"message":"The prompt is too long: 798932, model maximum context length: 262143"}}"#
        .utf8)
    let transport = VariedStatusTransport(callPlan: [
      (200, toolChunks),
      (400, [overflowBody]),
      (400, [overflowBody]),
    ])
    let client = Client(serverURL: URL(string: "http://test")!, transport: transport)
    let registry = ToolRegistry(tools: [AttachingTool()], logger: testLogger)
    let config = AgentLoopConfig(
      model: "test-model",
      client: client,
      toolExecutor: registry,
      chatTools: registry.chatTools,
      temperature: 0,
      maxToolRounds: .max,
      workingDirectory: FilePath("/tmp"),
      reasoningEnabled: nil,
      hooks: .default
    )
    let userMsg = Components.Schemas.ChatMessage(role: .user, content: .case1("read image"))
    do {
      _ = try await runAgentLoop(
        promptMessages: [userMsg],
        context: AgentContext(messages: []),
        config: config,
        emit: { _ in },
        logger: testLogger,
        abortObserver: AbortNotifier()
      )
      #expect(Bool(false), "expected error")
    } catch let ScribeError.apiHTTPError(statusCode, _, _) {
      #expect(statusCode == 400)
    } catch {
      #expect(Bool(false), "unexpected error: \(error)")
    }
  }

  @Test func midStreamAbortThrowsInterrupted() async throws {
    try await withTimeout(seconds: 5) {

      let chunks = [
        sseChunk(#"{"id":"1","choices":[{"index":0,"delta":{"content":"hello"}}]}"#),
        doneChunk(),
      ]
      let (messages, termination) = try await runLoop(
        prompt: "test",
        config: makeConfig(chunks: chunks),
        countingAbortObserver: CountingAbortObserver(triggerAt: 1)
      )
      expectTermination(termination, .interrupted)
      _ = messages
    }
  }

  @Test func emitsAgentAndTurnBoundaries() async throws {
    let chunks = [
      sseChunk(#"{"id":"1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"reply"}}]}"#),
      doneChunk(),
    ]
    let events = Mutex<[AgentEvent]>([])
    let userMsg = Components.Schemas.ChatMessage(role: .user, content: .case1("hello"))
    _ = try await runAgentLoop(
      promptMessages: [userMsg],
      context: AgentContext(messages: []),
      config: makeConfig(chunks: chunks),
      emit: { event in events.withLock { $0.append(event) } },
      logger: testLogger,
      abortObserver: AbortNotifier()
    )

    let captured = events.withLock { $0 }
    #expect(
      captured.contains(where: {
        if case .boundary(.agentStart) = $0 { return true }
        return false
      }))
    #expect(
      captured.contains(where: {
        if case .boundary(.agentEnd(.completed)) = $0 { return true }
        return false
      }))
    #expect(
      captured.contains(where: {
        if case .boundary(.turnStart(round: 1)) = $0 { return true }
        return false
      }))
    #expect(
      captured.contains(where: {
        if case .boundary(.turnEnd(round: 1, outcome: .completed)) = $0 { return true }
        return false
      }))
    #expect(
      captured.contains(where: {
        if case .boundary(.messageStart(role: .user, round: 0)) = $0 { return true }
        return false
      }))
    #expect(
      captured.contains(where: {
        if case .boundary(.messageStart(role: .assistant, round: 1)) = $0 { return true }
        return false
      }))
  }

  @Test func beforeToolCallCanBlockExecution() async throws {
    let toolChunks = [
      sseChunk(
        #"{"id":"1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"fake_tool","arguments":"{}"}}]}}]}"#
      ),
      doneChunk(),
    ]
    let replyChunks = [
      sseChunk(#"{"id":"2","choices":[{"index":0,"delta":{"content":"ok"}}]}"#),
      doneChunk(),
    ]
    let transport = FakeClientTransport(
      statusCode: 200, responseBodyChunksForCall: [toolChunks, replyChunks])
    let client = Client(serverURL: URL(string: "http://test")!, transport: transport)
    let registry = ToolRegistry(tools: [FakeTool()], logger: testLogger)
    let hooks = AgentLoopHooks(
      beforeToolCall: { _ in .block(reason: "denied by policy") }
    )
    let config = AgentLoopConfig(
      model: "test-model",
      client: client,
      toolExecutor: registry,
      chatTools: registry.chatTools,
      temperature: 0,
      maxToolRounds: .max,
      workingDirectory: FilePath("/tmp"),
      reasoningEnabled: nil,
      hooks: hooks
    )
    let (messages, termination) = try await runLoop(
      prompt: "test",
      config: config,
      abortNotifier: AbortNotifier()
    )
    expectTermination(termination, .completed)
    let toolMsg = messages.first { $0.role == .tool }
    #expect(stringContent(toolMsg!)?.contains("denied by policy") == true)
  }

  @Test func afterToolCallCanTerminateLoop() async throws {
    let toolChunks = [
      sseChunk(
        #"{"id":"1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"fake_tool","arguments":"{}"}}]}}]}"#
      ),
      doneChunk(),
    ]
    let transport = FakeClientTransport(statusCode: 200, responseBodyChunks: toolChunks)
    let client = Client(serverURL: URL(string: "http://test")!, transport: transport)
    let registry = ToolRegistry(tools: [FakeTool()], logger: testLogger)
    let hooks = AgentLoopHooks(
      afterToolCall: { _, result in
        AfterToolCallDecision(result: ToolResult.text("{\"stopped\":true}"), terminate: true)
      }
    )
    let config = AgentLoopConfig(
      model: "test-model",
      client: client,
      toolExecutor: registry,
      chatTools: registry.chatTools,
      temperature: 0,
      maxToolRounds: .max,
      workingDirectory: FilePath("/tmp"),
      reasoningEnabled: nil,
      hooks: hooks
    )
    let (messages, termination) = try await runLoop(
      prompt: "test",
      config: config,
      abortNotifier: AbortNotifier()
    )
    expectTermination(termination, .completed)

    #expect(messages.count == 3)
    #expect(messages[2].role == .tool)
    #expect(stringContent(messages[2])?.contains("stopped") == true)
  }

}

private func errorBody(_ message: String) -> HTTPBody.ByteChunk {

  let escaped = message.replacingOccurrences(of: "\"", with: "\\\"")
  return ArraySlice(#"{"error":{"message":"\#(escaped)"}}"#.utf8)
}
