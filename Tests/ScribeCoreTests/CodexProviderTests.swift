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

  /// Integration test: a `.configured` provider issues an HTTP request through the
  /// supplied transport, streams SSE text deltas as `AgentEvent` values, and
  /// produces a `TurnResult` containing the assistant message.
  @Test("run with configured client produces expected SSE response")
  func runWithConfiguredClientProducesExpectedResponse() async throws {
    // Given: a scripted transport that returns SSE text deltas followed by completion
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

    // When
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

    // Collect events and result BEFORE inspecting transport state
    var events: [AgentEvent] = []
    for await event in stream.events {
      events.append(event)
    }
    let result: TurnResult = try await stream.result.value

    // Then: the transport was called
    let bodies = transport.requestBodies
    #expect(bodies.count == 1, "Expected exactly one HTTP request")

    // Then: the request body carries the expected model and input
    let json = try #require(
      JSONSerialization.jsonObject(with: bodies[0]) as? [String: Any])
    #expect(json["model"] as? String == "codex-test-model")
    #expect(json["stream"] as? Bool == true)

    let input = try #require(json["input"] as? [[String: Any]])
    #expect(!input.isEmpty, "Expected non-empty input items")

    // Then: disabled reasoning is omitted from the request
    #expect(json["reasoning"] == nil)

    // Then: streamed text deltas appear as AgentEvent values
    let answerDeltas = events.filter {
      if case .output(.text(.answer, _)) = $0 { return true }
      return false
    }
    #expect(!answerDeltas.isEmpty, "Expected answer text deltas")

    let finalized = finalizedEvents(in: events)
    #expect(finalized.count == 1, "Expected exactly one .finalized event")

    // Then: the result is .completed with the expected assistant message
    #expect(result.outcome == TurnOutcome.completed)

    let assistantMessages = result.newMessages.filter { $0.role == .assistant }
    #expect(assistantMessages.count == 1, "Expected one assistant message")
    #expect(
      assistantMessages[0].content == "Hello world",
      "Expected assistant content to match streamed deltas")
  }
}
