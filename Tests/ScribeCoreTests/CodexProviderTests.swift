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

  // MARK: - ClientSource

  @Test("ClientSource.configured stores client")
  func configuredSourceStoresClient() {
    let transport = ScriptedTransport(status: 200, chunks: [])
    let client = ScribeLLMCodex.Client(
      serverURL: URL(string: "https://codex.example.com")!,
      transport: transport,
      middlewares: []
    )
    let source = CodexProvider.ClientSource.configured(client)

    if case .configured = source {
      // Success — the client is wrapped
    } else {
      Issue.record("Expected .configured source")
    }
  }

  @Test("ClientSource.credentials stores serverURL")
  func credentialsSourceStoresURL() {
    let url = URL(string: "https://codex.example.com")!
    let source = CodexProvider.ClientSource.credentials(serverURL: url)

    if case .credentials(let storedURL) = source {
      #expect(storedURL == url)
    } else {
      Issue.record("Expected .credentials source")
    }
  }

  // MARK: - Provider properties

  @Test("provider stores all configuration properties")
  func providerStoresProperties() {
    let transport = ScriptedTransport(status: 200, chunks: [])
    let client = ScribeLLMCodex.Client(
      serverURL: URL(string: "https://codex.example.com")!,
      transport: transport,
      middlewares: []
    )

    let provider = CodexProvider(
      source: .configured(client),
      model: "codex-model-v2",
      reasoningEnabled: true,
      reasoningEffort: "medium",
      contextWindow: 200_000
    )

    #expect(provider.model == "codex-model-v2")
    #expect(provider.reasoningEnabled == true)
    #expect(provider.reasoningEffort == "medium")
    #expect(provider.contextWindow == 200_000)
  }

  @Test("provider stores nil reasoning fields")
  func providerStoresNilReasoning() {
    let transport = ScriptedTransport(status: 200, chunks: [])
    let client = ScribeLLMCodex.Client(
      serverURL: URL(string: "https://codex.example.com")!,
      transport: transport,
      middlewares: []
    )

    let provider = CodexProvider(
      source: .configured(client),
      model: "codex-model",
      reasoningEnabled: nil,
      reasoningEffort: nil,
      contextWindow: 128_000
    )

    #expect(provider.reasoningEnabled == nil)
    #expect(provider.reasoningEffort == nil)
  }

  // MARK: - run method structure

  @Test("run returns a TurnStream with events and result")
  func runReturnsTurnStream() async throws {
    // A minimal SSE response — mimics Codex SSE format
    let sse =
      "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hi\"}\n\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_test\"}}\n\n"
    let chunkData = HTTPBody.ByteChunk(sse.utf8)
    let transport = ScriptedTransport(status: 200, chunks: [chunkData])
    let client = ScribeLLMCodex.Client(
      serverURL: URL(string: "https://codex.example.com")!,
      transport: transport,
      middlewares: []
    )

    let provider = CodexProvider(
      source: .configured(client),
      model: "codex-model",
      reasoningEnabled: nil,
      reasoningEffort: nil,
      contextWindow: 128_000
    )

    let stream = provider.run(
      promptMessages: [ScribeLLM.Components.Schemas.ChatMessage(role: .user, content: .case1("hello"))],
      history: [],
      options: AgentRunOptions(),
      toolExecutor: NoOpToolExecutor(),
      chatTools: [],
      workingDirectory: FilePath("/tmp"),
      logger: Logger(label: "test.codex-provider"),
      abortNotifier: AbortNotifier()
    )

    // Collect events
    var events: [AgentEvent] = []
    for await event in stream.events {
      events.append(event)
    }

    // Get result
    let result: TurnResult = try await stream.result.value

    // Should have completed with new messages
    #expect(result.outcome == TurnOutcome.completed)
    #expect(!result.newMessages.isEmpty)
    #expect(
      events.contains {
        if case .output(.finalized) = $0 { return true }
        return false
      })
  }

  @Test("run with configured source uses pre-configured client")
  func runWithConfiguredSourceUsesClient() async throws {
    let sse =
      "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hello from configured\"}\n\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_cfg\"}}\n\n"
    let transport = ScriptedTransport(status: 200, chunks: [.init(sse.utf8)])
    let client = ScribeLLMCodex.Client(
      serverURL: URL(string: "https://codex.example.com")!,
      transport: transport,
      middlewares: []
    )

    let provider = CodexProvider(
      source: .configured(client),
      model: "codex-model",
      reasoningEnabled: nil,
      reasoningEffort: nil,
      contextWindow: 128_000
    )

    let stream = provider.run(
      promptMessages: [ScribeLLM.Components.Schemas.ChatMessage(role: .user, content: .case1("test"))],
      history: [],
      options: AgentRunOptions(),
      toolExecutor: NoOpToolExecutor(),
      chatTools: [],
      workingDirectory: FilePath("/tmp"),
      logger: Logger(label: "test.configured"),
      abortNotifier: AbortNotifier()
    )

    let result: TurnResult = try await stream.result.value
    #expect(result.outcome == TurnOutcome.completed)
  }
}
