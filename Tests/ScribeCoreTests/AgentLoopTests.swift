import Foundation
import Logging
import ScribeCore
import ScribeLLM
import Synchronization
import Testing

// MARK: - Fakes

private struct FakeTool: ScribeTool {
  static var name: String { "fake_tool" }
  static var description: String { "A fake tool for testing." }
  static var parameters: [ScribeToolParameter] { [] }
  static var promptHint: String? { nil }

  struct Result: Encodable {
    let ok: Bool
    let echo: String
  }

  func run(arguments: String) async throws -> Encodable {
    Result(ok: true, echo: arguments)
  }
}

private final class TestHarness: AgentHarnessProtocol, Sendable {
  let model = "test-model"
  private let state: Mutex<State>

  private struct State {
    var callCount = 0
    var lastMessagesCount = 0
    var outcomes: [RoundOutcome] = []
  }

  init(outcomes: [RoundOutcome]) {
    state = Mutex(State(outcomes: outcomes))
  }

  var callCount: Int {
    state.withLock { $0.callCount }
  }

  func runRound(
    messages: inout [Components.Schemas.ChatMessage],
    logger: Logger,
    onEvent: @escaping @Sendable (TranscriptEvent) -> Void,
    shouldAbortTurn: @escaping @Sendable () -> Bool
  ) async throws -> RoundOutcome {
    let outcome = state.withLock { state -> RoundOutcome? in
      state.lastMessagesCount = messages.count
      guard state.callCount < state.outcomes.count else { return nil }
      defer { state.callCount += 1 }
      return state.outcomes[state.callCount]
    }
    guard let outcome else { return .completed }
    if case .toolCalls(let invocations) = outcome {
      let assistantMessage = Components.Schemas.ChatMessage(
        role: .assistant,
        content: "",
        name: nil,
        toolCalls: invocations.map { inv in
          Components.Schemas.AssistantToolCall(
            id: inv.id,
            _type: "function",
            function: .init(
              name: inv.name,
              arguments: inv.arguments
            )
          )
        },
        toolCallId: nil,
        reasoningContent: nil
      )
      messages.append(assistantMessage)
    }
    return outcome
  }
}

// These helpers still need @unchecked Sendable since they are used across
// isolation domains in tests. They are simple data holders without complex
// synchronization needs.
private final class EventCollector: @unchecked Sendable {
  var events: [TranscriptEvent] = []

  func append(_ event: TranscriptEvent) {
    events.append(event)
  }

  func contains(where predicate: (TranscriptEvent) -> Bool) -> Bool {
    events.contains(where: predicate)
  }
}

private final class AbortState: @unchecked Sendable {
  var value = false

  func set(_ newValue: Bool) {
    value = newValue
  }
}

// MARK: - Tests

@Suite
struct AgentLoopTests {
  @Test func completedRoundReturnsCompleted() async throws {
    let harness = TestHarness(outcomes: [.completed])
    let registry = ToolRegistry(tools: [FakeTool()])
    let loop = AgentLoop(
      harness: harness,
      registry: registry
    )
    var messages: [Components.Schemas.ChatMessage] = []
    let outcome = try await loop.runModelTurn(
      messages: &messages,
      logger: Logger(label: "test"),
      onEvent: { _ in }
    )
    #expect(outcome == .completed)
    #expect(harness.callCount == 1)
  }

  @Test func toolCallsAreExecutedAndMessagesAppended() async throws {
    let harness = TestHarness(outcomes: [
      .toolCalls([ToolInvocation(id: "call_1", name: "fake_tool", arguments: "{\"x\":1}")]),
      .completed,
    ])
    let registry = ToolRegistry(tools: [FakeTool()])
    let loop = AgentLoop(
      harness: harness,
      registry: registry
    )
    var messages: [Components.Schemas.ChatMessage] = []
    let outcome = try await loop.runModelTurn(
      messages: &messages,
      logger: Logger(label: "test"),
      onEvent: { _ in }
    )
    #expect(outcome == .completed)
    #expect(harness.callCount == 2)
    // One assistant message + one tool message should have been appended.
    #expect(messages.count == 2)
    #expect(messages[0].role == .assistant)
    #expect(messages[1].role == .tool)
    #expect(messages[1].toolCallId == "call_1")
  }

  @Test func abortBeforeRoundReturnsInterrupted() async throws {
    let harness = TestHarness(outcomes: [.completed])
    let registry = ToolRegistry(tools: [FakeTool()])
    let loop = AgentLoop(
      harness: harness,
      registry: registry
    )
    var messages: [Components.Schemas.ChatMessage] = []
    let outcome = try await loop.runModelTurn(
      messages: &messages,
      logger: Logger(label: "test"),
      onEvent: { _ in },
      shouldAbortTurn: { true }
    )
    #expect(outcome == .interrupted)
    #expect(harness.callCount == 0)
  }

  @Test func abortBeforeToolReturnsInterrupted() async throws {
    let harness = TestHarness(outcomes: [
      .toolCalls([ToolInvocation(id: "call_1", name: "fake_tool", arguments: "{}")])
    ])
    let registry = ToolRegistry(tools: [FakeTool()])
    let loop = AgentLoop(
      harness: harness,
      registry: registry
    )
    var messages: [Components.Schemas.ChatMessage] = []
    let state = AbortState()
    let outcome = try await loop.runModelTurn(
      messages: &messages,
      logger: Logger(label: "test"),
      onEvent: { _ in },
      shouldAbortTurn: {
        if state.value {
          return true
        }
        state.set(true)
        return false
      }
    )
    #expect(outcome == .interrupted)
    #expect(harness.callCount == 1)
  }

  @Test func unknownToolEmitsWarningEvent() async throws {
    let harness = TestHarness(outcomes: [
      .toolCalls([ToolInvocation(id: "call_1", name: "missing_tool", arguments: "{}")]),
      .completed,
    ])
    let registry = ToolRegistry(tools: [FakeTool()])
    let collector = EventCollector()
    let loop = AgentLoop(
      harness: harness,
      registry: registry
    )
    var messages: [Components.Schemas.ChatMessage] = []
    let outcome = try await loop.runModelTurn(
      messages: &messages,
      logger: Logger(label: "test"),
      onEvent: { collector.append($0) }
    )
    #expect(outcome == .completed)
    let hasToolEvent = collector.contains(where: {
      if case .toolInvocation(let name, _, _) = $0, name == "missing_tool" { return true }
      return false
    })
    #expect(hasToolEvent)
  }
}
