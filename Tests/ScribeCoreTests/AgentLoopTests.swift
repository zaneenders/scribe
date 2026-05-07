import Foundation
import Logging
import ScribeCLI
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
    var throwInterruptedOnCall: Int? = nil
  }

  init(outcomes: [RoundOutcome]) {
    state = Mutex(State(outcomes: outcomes))
  }

  /// Creates a harness that throws `AgentTurnInterruptedError` on the first call
  /// and returns the given outcomes thereafter.
  init(throwInterruptedThen outcomes: [RoundOutcome]) {
    state = Mutex(State(outcomes: outcomes, throwInterruptedOnCall: 0))
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
    let (maybeOutcome, shouldThrow) = state.withLock { state -> (RoundOutcome?, Bool) in
      state.lastMessagesCount = messages.count
      let shouldThrow = state.throwInterruptedOnCall == state.callCount
      let outcome: RoundOutcome?
      if !shouldThrow {
        guard state.callCount < state.outcomes.count else { return (nil, false) }
        outcome = state.outcomes[state.callCount]
      } else {
        outcome = nil
      }
      state.callCount += 1
      return (outcome, shouldThrow)
    }
    if shouldThrow { throw AgentTurnInterruptedError() }
    guard let outcome = maybeOutcome else { return .completed }
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
    } else {
      // .completed — append an assistant message like the real AgentHarness does
      messages.append(
        Components.Schemas.ChatMessage(
          role: .assistant,
          content: "",
          name: nil,
          toolCalls: nil,
          toolCallId: nil,
          reasoningContent: nil
        ))
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

final class AbortState: @unchecked Sendable {
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
    // 1 assistant (toolCalls round) + 1 tool message + 1 final assistant = 3
    #expect(messages.count == 3)
    #expect(messages[0].role == .assistant)
    #expect(messages[1].role == .tool)
    #expect(messages[1].toolCallId == "call_1")
    #expect(messages[2].role == .assistant)
  }

  @Test func abortBeforeRoundReturnsInterrupted() async throws {
    let harness = TestHarness(outcomes: [.completed])
    let registry = ToolRegistry(tools: [FakeTool()])
    let loop = AgentLoop(
      harness: harness,
      registry: registry
    )
    var messages: [Components.Schemas.ChatMessage] = []
    do {
      _ = try await loop.runModelTurn(
        messages: &messages,
        logger: Logger(label: "test"),
        onEvent: { _ in },
        shouldAbortTurn: { true }
      )
      #expect(Bool(false), "expected AgentTurnInterruptedError")
    } catch is AgentTurnInterruptedError {
      // Expected — before-http abort now throws
    }
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
    do {
      _ = try await loop.runModelTurn(
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
      #expect(Bool(false), "expected AgentTurnInterruptedError")
    } catch is AgentTurnInterruptedError {
      // Expected — post-stream-pre-tools abort now throws
    }
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

  // MARK: - Interrupted error from harness

  @Test func interruptedErrorFromHarnessReturnsInterrupted() async throws {
    let harness = TestHarness(throwInterruptedThen: [.completed])
    let registry = ToolRegistry(tools: [FakeTool()])
    let loop = AgentLoop(harness: harness, registry: registry)

    var messages: [Components.Schemas.ChatMessage] = []
    let outcome = try await loop.runModelTurn(
      messages: &messages,
      logger: Logger(label: "test"),
      onEvent: { _ in }
    )
    #expect(outcome == .interrupted)
    #expect(harness.callCount == 1)
  }

  // MARK: - Tool round limit

  @Test func toolRoundLimitReturnsLimitOutcome() async throws {
    // Harness keeps returning toolCalls, but maxToolRounds=1 stops after first.
    let harness = TestHarness(outcomes: [
      .toolCalls([ToolInvocation(id: "c1", name: "fake_tool", arguments: "{}")]),
      .completed,  // would be reached if limit didn't fire
    ])
    let registry = ToolRegistry(tools: [FakeTool()])
    let loop = AgentLoop(harness: harness, registry: registry)

    var messages: [Components.Schemas.ChatMessage] = []
    let outcome = try await loop.runModelTurn(
      messages: &messages,
      logger: Logger(label: "test"),
      onEvent: { _ in },
      maxToolRounds: 1
    )
    #expect(outcome == .toolRoundLimit(rounds: 1))
    // Harness should have been called only once (limit hit before second call).
    #expect(harness.callCount == 1)
  }

  @Test func toolRoundLimitCleansUpMessages() async throws {
    // When the limit fires, messages added during the final round are rolled back.
    let harness = TestHarness(outcomes: [
      .toolCalls([ToolInvocation(id: "c1", name: "fake_tool", arguments: "{}")]),
      .completed,
    ])
    let registry = ToolRegistry(tools: [FakeTool()])
    let loop = AgentLoop(harness: harness, registry: registry)

    var messages: [Components.Schemas.ChatMessage] = [
      Components.Schemas.ChatMessage(role: .user, content: "hi")
    ]
    let outcome = try await loop.runModelTurn(
      messages: &messages,
      logger: Logger(label: "test"),
      onEvent: { _ in },
      maxToolRounds: 1
    )
    #expect(outcome == .toolRoundLimit(rounds: 1))
    // The harness appends an assistant message; on limit the loop removes it.
    // Only the original user message should remain.
    #expect(messages.count == 1)
    #expect(messages[0].role == .user)
  }

  // MARK: - Pre-tool abort

  @Test func abortPreToolReturnsInterrupted() async throws {
    let harness = TestHarness(outcomes: [
      .toolCalls([
        ToolInvocation(id: "c1", name: "fake_tool", arguments: "{}"),
        ToolInvocation(id: "c2", name: "fake_tool", arguments: "{}"),
      ])
    ])
    let registry = ToolRegistry(tools: [FakeTool()])
    let loop = AgentLoop(harness: harness, registry: registry)

    // Abort at the pre-tool check for the second tool. shouldAbortTurn is called
    // multiple times per tool (pre-tool check, ToolRegistry abort-before-start,
    // polling loop). We use a counter that only triggers after the first tool has
    // finished all its internal checks.
    final class CallCounter: @unchecked Sendable { var count = 0 }
    let counter = CallCounter()
    var messages: [Components.Schemas.ChatMessage] = []
    let outcome = try await loop.runModelTurn(
      messages: &messages,
      logger: Logger(label: "test"),
      onEvent: { _ in },
      shouldAbortTurn: {
        counter.count += 1
        return counter.count == 6
      }
    )
    #expect(outcome == .interrupted)
    // All messages added during this round are rolled back.
    #expect(messages.count == 0)
  }

  // MARK: - Multiple tool calls in one round

  @Test func multipleToolCallsInSingleRound() async throws {
    let harness = TestHarness(outcomes: [
      .toolCalls([
        ToolInvocation(id: "c1", name: "fake_tool", arguments: #"{"a":1}"#),
        ToolInvocation(id: "c2", name: "fake_tool", arguments: #"{"b":2}"#),
      ]),
      .completed,
    ])
    let registry = ToolRegistry(tools: [FakeTool()])
    let loop = AgentLoop(harness: harness, registry: registry)

    var messages: [Components.Schemas.ChatMessage] = []
    let outcome = try await loop.runModelTurn(
      messages: &messages,
      logger: Logger(label: "test"),
      onEvent: { _ in }
    )
    #expect(outcome == .completed)
    // 1 assistant + 2 tool messages + 1 final assistant = 4
    #expect(messages.count == 4)
    #expect(messages[0].role == .assistant)
    #expect(messages[1].role == .tool)
    #expect(messages[1].toolCallId == "c1")
    #expect(messages[2].role == .tool)
    #expect(messages[2].toolCallId == "c2")
    #expect(messages[3].role == .assistant)
  }

  // MARK: - Event emission

  @Test func emitsToolRoundHeaderEvent() async throws {
    let harness = TestHarness(outcomes: [
      .toolCalls([ToolInvocation(id: "c1", name: "fake_tool", arguments: "{}")]),
      .completed,
    ])
    let registry = ToolRegistry(tools: [FakeTool()])
    let collector = EventCollector()
    let loop = AgentLoop(harness: harness, registry: registry)

    var messages: [Components.Schemas.ChatMessage] = []
    _ = try await loop.runModelTurn(
      messages: &messages,
      logger: Logger(label: "test"),
      onEvent: { collector.append($0) }
    )
    let hasHeader = collector.contains(where: {
      if case .toolRoundHeader(let round, let names) = $0,
        round == 1, names == ["fake_tool"]
      {
        return true
      }
      return false
    })
    #expect(hasHeader)
  }

  @Test func emitsToolInvocationAndBlankLineEvents() async throws {
    let harness = TestHarness(outcomes: [
      .toolCalls([ToolInvocation(id: "c1", name: "fake_tool", arguments: #"{"x":1}"#)]),
      .completed,
    ])
    let registry = ToolRegistry(tools: [FakeTool()])
    let collector = EventCollector()
    let loop = AgentLoop(harness: harness, registry: registry)

    var messages: [Components.Schemas.ChatMessage] = []
    _ = try await loop.runModelTurn(
      messages: &messages,
      logger: Logger(label: "test"),
      onEvent: { collector.append($0) }
    )

    let invocation = collector.events.first(where: {
      if case .toolInvocation = $0 { return true }
      return false
    })
    guard case .toolInvocation(let name, let args, let output) = invocation else {
      #expect(Bool(false), "expected toolInvocation event")
      return
    }
    #expect(name == "fake_tool")
    #expect(args == #"{"x":1}"#)
    // FakeTool echoes the arguments as JSON; output is non-empty and self-describing.
    #expect(!output.isEmpty)
    #expect(output.contains("ok"))

    // Blank line should follow the tool invocation
    let invIndex = collector.events.firstIndex(where: {
      if case .toolInvocation = $0 { return true }
      return false
    })
    guard let idx = invIndex, idx + 1 < collector.events.count else {
      #expect(Bool(false), "expected blankLine after toolInvocation")
      return
    }
    if case .blankLine = collector.events[idx + 1] {
      // expected
    } else {
      #expect(Bool(false), "expected blankLine after toolInvocation")
    }
  }
}
