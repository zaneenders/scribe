import Foundation
import HTTPTypes
import Logging
import OpenAPIRuntime
import ScribeLLM
import SystemPackage
import Testing

@testable import ScribeCore
@testable import ScribeLLMCodex

@Suite
struct CodexProviderTests {

  @Test("run with configured client produces expected SSE response")
  func runWithConfiguredClientProducesExpectedResponse() async throws {
    let transport = ScriptedTransport(
      status: 200,
      chunks: sseChunks(
        #"{"type":"response.output_text.delta","delta":"Hello"}"#,
        #"{"type":"response.output_text.delta","delta":" world"}"#,
        #"{"type":"response.completed","response":{"id":"resp_test","usage":{"input_tokens":10,"output_tokens":5,"total_tokens":15}}}"#
      )
    )
    let serverURL = URL(string: "https://codex.example.com")!
    let client = ScribeLLMCodex.Client(
      serverURL: serverURL,
      transport: transport,
      middlewares: []
    )

    let provider = CodexProvider(
      source: .configured(client),
      model: "codex-test-model",
      reasoningEnabled: false,
      reasoningEffort: nil,
      contextWindow: 128_000
    )

    let stream = provider.run(
      promptMessages: [
        ScribeLLM.Components.Schemas.ChatMessage(
          role: .user, content: .case1("hello"))
      ],
      history: [],
      options: AgentRunOptions(),
      toolExecutor: NoOpToolExecutor(),
      chatTools: [],
      workingDirectory: FilePath("/tmp"),
      logger: testLogger,
      abortNotifier: AbortNotifier()
    )

    var events: [AgentEvent] = []
    for await event in stream.events {
      events.append(event)
    }
    let result: TurnResult = try await stream.result.value

    let requests = transport.capturedRequests
    #expect(requests.count == 1, "Expected exactly one HTTP request")

    let req = requests[0]
    #expect(req.method == .post)
    #expect(req.baseURL == serverURL)

    let bodyData = try #require(req.body)
    let json = try #require(
      JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
    #expect(json["model"] as? String == "codex-test-model")
    #expect(json["stream"] as? Bool == true)

    let input = try #require(json["input"] as? [[String: Any]])
    #expect(!input.isEmpty, "Expected non-empty input items")

    #expect(json["reasoning"] == nil)

    let answerDeltas = events.filter {
      if case .output(.text(.answer, _)) = $0 { return true }
      return false
    }
    #expect(!answerDeltas.isEmpty, "Expected answer text deltas")

    let finalized = finalizedEvents(in: events)
    #expect(finalized.count == 1, "Expected exactly one .finalized event")

    #expect(result.outcome == TurnOutcome.completed)

    let assistantMessages = result.newMessages.filter { $0.role == .assistant }
    #expect(assistantMessages.count == 1, "Expected one assistant message")
    #expect(
      assistantMessages[0].content == "Hello world",
      "Expected assistant content to match streamed deltas")
  }

  @Test("retries a Codex server_error event before visible output")
  func retriesCodexServerErrorEvent() async throws {
    let transport = ScriptedTransport(responses: [
      .init(
        status: 200,
        chunks: sseChunks(
          #"{"type":"error","code":"server_error","message":"An error occurred while processing your request."}"#
        )),
      .init(
        status: 200,
        chunks: sseChunks(
          #"{"type":"response.output_text.delta","delta":"Recovered"}"#,
          #"{"type":"response.completed","response":{"id":"resp_retry"}}"#
        )),
    ])
    let client = ScribeLLMCodex.Client(
      serverURL: URL(string: "https://codex.example.com")!,
      transport: transport,
      middlewares: []
    )
    let provider = CodexProvider(
      source: .configured(client),
      model: "codex-test-model",
      reasoningEnabled: false,
      reasoningEffort: nil,
      contextWindow: 128_000,
      retryPolicy: .fastTestPolicy
    )

    let stream = provider.run(
      promptMessages: [
        ScribeLLM.Components.Schemas.ChatMessage(role: .user, content: .case1("hello"))
      ],
      history: [],
      options: AgentRunOptions(),
      toolExecutor: NoOpToolExecutor(),
      chatTools: [],
      workingDirectory: FilePath("/tmp"),
      logger: testLogger,
      abortNotifier: AbortNotifier()
    )

    var retryAttempts: [Int] = []
    for await event in stream.events {
      if case .lifecycle(.retrying(let attempt, _, _, _)) = event {
        retryAttempts.append(attempt)
      }
    }
    let result = try await stream.result.value

    #expect(transport.capturedRequests.count == 2)
    #expect(retryAttempts == [1])
    #expect(result.outcome == .completed)
    #expect(result.newMessages.last?.content == "Recovered")
  }
}
