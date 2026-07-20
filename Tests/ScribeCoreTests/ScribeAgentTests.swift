import Foundation
import HTTPTypes
import Logging
import OpenAPIRuntime
import ScribeCore
import ScribeLLM
import Synchronization
import SystemPackage
import Testing

// MARK: - Shared helpers (kept minimal — loop-level tests own detailed behaviour)

private let defaultHistory: [ScribeMessage] = [
  ScribeMessage(role: .system, content: "You are a test agent.")
]

private func makeAgent(
  statusCode: Int = 200,
  chunks: [HTTPBody.ByteChunk],
  model: String = "test-model",
  tools: [any ScribeTool] = []
) -> ScribeAgent {
  let transport = ScriptedTransport(status: statusCode, chunks: chunks)
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

// MARK: -

@Suite
struct ScribeAgentTests {

  // MARK: - Input wiring

  @Test func stringInputIsConvertedToUserMessage() async throws {
    let chunks = [
      sseChunk(#"{"id":"1","choices":[{"index":0,"delta":{"content":"ack"}}]}"#),
      doneChunk(),
    ]
    let agent = makeAgent(chunks: chunks)
    let ts = agent.run("hello", history: defaultHistory)
    Task { for await _ in ts.events {} }
    let result = try await ts.result.value

    #expect(result.outcome == .completed)
    #expect(result.newMessages.first(where: { $0.role == .user })?.content == "hello")
  }

  @Test func scribeMessageArrayInputOverload() async throws {
    let chunks = [
      sseChunk(#"{"id":"1","choices":[{"index":0,"delta":{"content":"ack"}}]}"#),
      doneChunk(),
    ]
    let agent = makeAgent(chunks: chunks)
    let userMsg = ScribeMessage(role: .user, content: "from array")
    let ts = agent.run([userMsg], history: defaultHistory)
    Task { for await _ in ts.events {} }
    let result = try await ts.result.value
    #expect(result.outcome == .completed)
    #expect(result.newMessages.last?.role == .assistant)
    #expect(result.newMessages.last?.content == "ack")
  }

  // MARK: - Abort lifecycle

  @Test func abortBetweenRunsDoesNotLeak() async throws {
    let chunks = [
      sseChunk(#"{"id":"1","choices":[{"index":0,"delta":{"content":"ok"}}]}"#),
      doneChunk(),
    ]
    let agent = makeAgent(chunks: chunks)
    agent.abort()
    let ts = agent.run("test", history: defaultHistory)
    Task { for await _ in ts.events {} }
    let result = try await ts.result.value
    #expect(result.outcome == .completed)
  }

  // MARK: - Custom ToolExecutor

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
    let transport = ScriptedTransport(responses: [
      ScriptedTransport.Response(status: 200, chunks: toolChunks),
      ScriptedTransport.Response(status: 200, chunks: replyChunks),
    ])
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
    let result = try await ts.result.value
    #expect(result.outcome == .completed)

    let recorded = recorder.invocations.withLock { $0 }
    #expect(recorded.count == 1)
    #expect(recorded.first?.name == "unreachable")
    #expect(recorded.first?.id == "c1")
    #expect(recorded.first?.arguments == #"{"k":1}"#)

    let toolMessage = result.newMessages.first { $0.role == .tool }
    #expect(stringContent(toolMessage) == recorder.canned)
  }

  // MARK: - TurnStream: events + result consumption

  @Test func turnStreamEventsAndResultCanBothBeConsumed() async throws {
    let chunks = [
      sseChunk(#"{"id":"1","choices":[{"index":0,"delta":{"content":"hello"}}]}"#),
      sseChunk(#"{"id":"1","choices":[{"index":0,"delta":{"content":" world"}}]}"#),
      doneChunk(),
    ]
    let agent = makeAgent(chunks: chunks)
    let ts = agent.run("greet", history: defaultHistory)

    // Consume events
    var eventCount = 0
    for await _ in ts.events { eventCount += 1 }

    // Then consume the result
    let result = try await ts.result.value
    #expect(result.outcome == .completed)
    #expect(eventCount > 0)
  }
}

private func stringContent(_ msg: ScribeMessage?) -> String? {
  guard let msg else { return nil }
  return msg.content.isEmpty ? nil : msg.content
}
