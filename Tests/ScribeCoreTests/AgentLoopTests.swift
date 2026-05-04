import Foundation
import Logging
import ScribeCore
import ScribeLLM
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

private final class FakeHarness: @unchecked Sendable {
  var callCount = 0
  var lastMessagesCount = 0
  let outcomes: [RoundOutcome]
  let tools: [Components.Schemas.ChatTool]

  init(outcomes: [RoundOutcome], tools: [Components.Schemas.ChatTool] = []) {
    self.outcomes = outcomes
    self.tools = tools
  }

  func nextOutcome() -> RoundOutcome? {
    guard callCount < outcomes.count else { return nil }
    defer { callCount += 1 }
    return outcomes[callCount]
  }
}

extension FakeHarness: AgentHarnessProtocol {
  nonisolated var model: String { "fake-model" }

  func runRound(
    messages: inout [Components.Schemas.ChatMessage],
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
    }
    return outcome
  }
}

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
    let harness = FakeHarness(outcomes: [.completed])
    let registry = ToolRegistry(tools: [FakeTool()])
    let loop = AgentLoop(
      harness: harness,
      registry: registry,
      maxToolRounds: 5,
      onEvent: { _ in }
    )
    var messages: [Components.Schemas.ChatMessage] = []
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
      maxToolRounds: 5,
      onEvent: { _ in }
    )
    var messages: [Components.Schemas.ChatMessage] = []
    let outcome = try await loop.runModelTurn(
      messages: &messages,
      logger: Logger(label: "test")
    )
    #expect(outcome == .completed)
    #expect(harness.callCount == 2)
    // One assistant message + one tool message should have been appended.
    #expect(messages.count == 2)
    #expect(messages[0].role == .assistant)
    #expect(messages[1].role == .tool)
    #expect(messages[1].toolCallId == "call_1")
  }

  @Test func hitToolRoundLimitWhenMaxRoundsExceeded() async throws {
    let harness = FakeHarness(
      outcomes: Array(
        repeating: .toolCalls([ToolInvocation(id: "call_1", name: "fake_tool", arguments: "{}")]), count: 10))
    let registry = ToolRegistry(tools: [FakeTool()])
    let collector = EventCollector()
    let loop = AgentLoop(
      harness: harness,
      registry: registry,
      maxToolRounds: 2,
      onEvent: { collector.append($0) }
    )
    var messages: [Components.Schemas.ChatMessage] = []
    let outcome = try await loop.runModelTurn(
      messages: &messages,
      logger: Logger(label: "test")
    )
    #expect(outcome == .hitToolRoundLimit)
    #expect(harness.callCount == 2)
    #expect(collector.contains(where: { if case .maxToolRoundsExceeded = $0 { true } else { false } }))
  }

  @Test func abortBeforeRoundThrowsInterrupted() async throws {
    let harness = FakeHarness(outcomes: [.completed])
    let registry = ToolRegistry(tools: [FakeTool()])
    let loop = AgentLoop(
      harness: harness,
      registry: registry,
      maxToolRounds: 5,
      onEvent: { _ in }
    )
    var messages: [Components.Schemas.ChatMessage] = []
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
      maxToolRounds: 5,
      onEvent: { _ in }
    )
    var messages: [Components.Schemas.ChatMessage] = []
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
      maxToolRounds: 5,
      onEvent: { collector.append($0) }
    )
    var messages: [Components.Schemas.ChatMessage] = []
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
}
