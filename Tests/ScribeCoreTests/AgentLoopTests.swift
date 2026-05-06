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

private final class FakeHarness: Sendable {
  private let _state = Mutex(FakeHarness.State())
  let outcomes: [RoundOutcome]
  let tools: [Components.Schemas.ChatTool]

  private struct State {
    var callCount = 0
    var lastMessagesCount = 0
    /// Optional callback so the harness can emit events the real harness would
    /// (e.g. `.messageCountChanged`).
    var onEvent: (@Sendable (TranscriptEvent) -> Void)?
  }

  var callCount: Int { _state.withLock { $0.callCount } }
  var lastMessagesCount: Int {
    get { _state.withLock { $0.lastMessagesCount } }
    set { _state.withLock { $0.lastMessagesCount = newValue } }
  }
  var onEvent: (@Sendable (TranscriptEvent) -> Void)? {
    get { _state.withLock { $0.onEvent } }
    set { _state.withLock { $0.onEvent = newValue } }
  }

  init(
    outcomes: [RoundOutcome],
    tools: [Components.Schemas.ChatTool] = [],
    onEvent: (@Sendable (TranscriptEvent) -> Void)? = nil
  ) {
    self.outcomes = outcomes
    self.tools = tools
    self.onEvent = onEvent
  }

  func nextOutcome() -> RoundOutcome? {
    _state.withLock { state in
      guard state.callCount < outcomes.count else { return nil }
      defer { state.callCount += 1 }
      return outcomes[state.callCount]
    }
  }
}

extension FakeHarness: AgentHarnessProtocol {
  nonisolated var model: String { "fake-model" }

  func runRound(
    messages: inout MessageRope,
    logger: Logger,
    shouldAbortTurn: @escaping @Sendable () -> Bool
  ) async throws -> RoundOutcome {
    lastMessagesCount = messages.count
    guard let outcome = nextOutcome() else {
      return .completed
    }
    if case .toolCalls(let invocations) = outcome {
      let assistantMessage = Components.Schemas.ChatMessage(
        role: .assistant,
        content: "",
        name: nil,
        toolCalls: invocations.map {
          .init(id: $0.id, _type: "function", function: .init(name: $0.name, arguments: $0.arguments))
        },
        toolCallId: nil,
        reasoningContent: nil
      )
      messages.append(assistantMessage)
      onEvent?(.messageCountChanged(messages.count))
    }
    return outcome
  }
}

private final class EventCollector: Sendable {
  private let _events = Mutex<[TranscriptEvent]>([])

  var events: [TranscriptEvent] { _events.withLock { $0 } }

  func append(_ event: TranscriptEvent) {
    _events.withLock { $0.append(event) }
  }

  func contains(where predicate: (TranscriptEvent) -> Bool) -> Bool {
    _events.withLock { $0.contains(where: predicate) }
  }
}

private final class AbortState: Sendable {
  private let _value = Mutex(false)

  var value: Bool { _value.withLock { $0 } }

  func set(_ newValue: Bool) {
    _value.withLock { $0 = newValue }
  }
}

// MARK: - Tests

@Suite
struct AgentLoopTests {
  @Test func completedRoundReturnsCompleted() async throws {
    let harness = FakeHarness(outcomes: [.completed])
    let registry = ToolRegistry(tools: [FakeTool()])
    let loop = AgentLoop(
      harness: harness,
      registry: registry,
      onEvent: { _ in }
    )
    var messages = MessageRope()
    let outcome = try await loop.runModelTurn(
      messages: &messages,
      logger: Logger(label: "test")
    )
    #expect(outcome == .completed)
    #expect(harness.callCount == 1)
  }

  @Test func toolCallsAreExecutedAndMessagesAppended() async throws {
    let harness = FakeHarness(outcomes: [
      .toolCalls([ToolInvocation(id: "call_1", name: "fake_tool", arguments: "{\"x\":1}")]),
      .completed,
    ])
    let registry = ToolRegistry(tools: [FakeTool()])
    let loop = AgentLoop(
      harness: harness,
      registry: registry,
      onEvent: { _ in }
    )
    var messages = MessageRope()
    let outcome = try await loop.runModelTurn(
      messages: &messages,
      logger: Logger(label: "test")
    )
    #expect(outcome == .completed)
    #expect(harness.callCount == 2)
    // One assistant message + one tool message should have been appended.
    #expect(messages.count == 2)
    let msgs = messages.window(from: 0, count: 2)
    #expect(msgs[0].role == .assistant)
    #expect(msgs[1].role == .tool)
    #expect(msgs[1].toolCallId == "call_1")
  }

  @Test func abortBeforeRoundThrowsInterrupted() async throws {
    let harness = FakeHarness(outcomes: [.completed])
    let registry = ToolRegistry(tools: [FakeTool()])
    let loop = AgentLoop(
      harness: harness,
      registry: registry,
      onEvent: { _ in }
    )
    var messages = MessageRope()
    do {
      _ = try await loop.runModelTurn(
        messages: &messages,
        logger: Logger(label: "test"),
        shouldAbortTurn: { true }
      )
      #expect(Bool(false))
    } catch is AgentTurnInterruptedError {
      // expected
    }
    #expect(harness.callCount == 0)
  }

  @Test func abortBeforeToolThrowsInterrupted() async throws {
    let harness = FakeHarness(outcomes: [
      .toolCalls([ToolInvocation(id: "call_1", name: "fake_tool", arguments: "{}")])
    ])
    let registry = ToolRegistry(tools: [FakeTool()])
    let loop = AgentLoop(
      harness: harness,
      registry: registry,
      onEvent: { _ in }
    )
    var messages = MessageRope()
    let state = AbortState()
    do {
      _ = try await loop.runModelTurn(
        messages: &messages,
        logger: Logger(label: "test"),
        shouldAbortTurn: {
          if state.value {
            return true
          }
          state.set(true)
          return false
        }
      )
      #expect(Bool(false))
    } catch is AgentTurnInterruptedError {
      // expected
    }
    #expect(harness.callCount == 1)
  }

  @Test func unknownToolEmitsWarningEvent() async throws {
    let harness = FakeHarness(outcomes: [
      .toolCalls([ToolInvocation(id: "call_1", name: "missing_tool", arguments: "{}")]),
      .completed,
    ])
    let registry = ToolRegistry(tools: [FakeTool()])
    let collector = EventCollector()
    let loop = AgentLoop(
      harness: harness,
      registry: registry,
      onEvent: { collector.append($0) }
    )
    var messages = MessageRope()
    let outcome = try await loop.runModelTurn(
      messages: &messages,
      logger: Logger(label: "test")
    )
    #expect(outcome == .completed)
    let hasToolEvent = collector.contains(where: {
      if case .toolInvocation(let name, _, _) = $0, name == "missing_tool" { return true }
      return false
    })
    #expect(hasToolEvent)
  }

  // MARK: - messageCountChanged events

  @Test func emitsMessageCountChangedAfterToolMessageAppend() async throws {
    let collector = EventCollector()
    let harness = FakeHarness(
      outcomes: [
        .toolCalls([ToolInvocation(id: "call_1", name: "fake_tool", arguments: "{}")]),
        .completed,
      ],
      onEvent: { collector.append($0) }
    )
    let registry = ToolRegistry(tools: [FakeTool()])
    let loop = AgentLoop(
      harness: harness,
      registry: registry,
      onEvent: { collector.append($0) }
    )
    var messages = MessageRope()
    _ = try await loop.runModelTurn(
      messages: &messages,
      logger: Logger(label: "test")
    )

    // The harness fired .messageCountChanged when it appended the assistant
    // message with tool calls (count becomes 1).
    let harnessFired = collector.contains(where: {
      if case .messageCountChanged(let c) = $0, c == 1 { return true }
      return false
    })
    #expect(harnessFired, "Harness should emit .messageCountChanged after appending assistant message")

    // AgentLoop fired .messageCountChanged after appending the tool result
    // message (count becomes 2).
    let loopFired = collector.contains(where: {
      if case .messageCountChanged(let c) = $0, c == 2 { return true }
      return false
    })
    #expect(loopFired, "AgentLoop should emit .messageCountChanged after appending tool message")
  }

  @Test func messageCountChangedReflectsRopeCountAfterEachAppend() async throws {
    let collector = EventCollector()
    let harness = FakeHarness(
      outcomes: [
        .toolCalls([
          ToolInvocation(id: "c1", name: "fake_tool", arguments: "{}"),
          ToolInvocation(id: "c2", name: "fake_tool", arguments: "{}"),
        ]),
        .completed,
      ],
      onEvent: { collector.append($0) }
    )
    let registry = ToolRegistry(tools: [FakeTool()])
    let loop = AgentLoop(
      harness: harness,
      registry: registry,
      onEvent: { collector.append($0) }
    )
    var messages = MessageRope()
    _ = try await loop.runModelTurn(
      messages: &messages,
      logger: Logger(label: "test")
    )

    // Extract .messageCountChanged values in order.
    let counts: [Int] = collector.events.compactMap {
      if case .messageCountChanged(let c) = $0 { return c }
      return nil
    }
    #expect(!counts.isEmpty)
    // Counts should be non-decreasing.
    for i in 1..<counts.count {
      #expect(counts[i] > counts[i - 1], "messageCountChanged counts must increase monotonically")
    }
    // Final count should match the rope.
    #expect(counts.last == messages.count)
  }

  // MARK: - bootstrap / history ownership

  @Test func bootstrapSeedsHistoryWithSystemPrompt() async throws {
    let agent = try ScribeAgent(
      configuration: AgentConfig(agentModel: "test", serverURL: "http://127.0.0.1:1"),
      systemPrompt: "You are a test assistant.",
      tools: [FakeTool()]
    )

    // The rope should contain exactly one message: the system prompt.
    #expect(agent.history.count == 1)
    #expect(agent.history.first?.role == Components.Schemas.ChatMessage.RolePayload.system)
    #expect(agent.history.first?.content == "You are a test assistant.")
  }
}
