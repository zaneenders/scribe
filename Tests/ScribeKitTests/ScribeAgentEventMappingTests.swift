import Foundation
import ScribeCore
import Testing

@testable import ScribeKit

@Suite
struct ScribeAgentEventMappingTests {

  @Test func outputEventsMapToSectionAndTextEvents() {
    #expect(
      ScribeAgentEventMapper.map(.output(.sectionStarted(.reasoning, previous: nil)))
        == .sectionStarted(.reasoning))
    #expect(
      ScribeAgentEventMapper.map(.output(.sectionStarted(.answer, previous: .reasoning)))
        == .sectionStarted(.answer))
    #expect(
      ScribeAgentEventMapper.map(.output(.text(.reasoning, "thinking")))
        == .sectionTextAppended(.reasoning, text: "thinking"))
    #expect(
      ScribeAgentEventMapper.map(.output(.text(.answer, "hello")))
        == .sectionTextAppended(.answer, text: "hello"))
    #expect(ScribeAgentEventMapper.map(.output(.empty)) == .emptyOutput)
    #expect(ScribeAgentEventMapper.map(.output(.finalized)) == nil)
  }

  @Test func toolAndLifecycleEventsMapToStructuredEvents() {
    #expect(
      ScribeAgentEventMapper.map(
        .boundary(.toolExecutionStart(name: "shell", arguments: #"{"command":"ls"}"#))
      ) == .toolInvocationStarted(name: "shell", arguments: #"{"command":"ls"}"#))
    #expect(
      ScribeAgentEventMapper.map(
        .boundary(.toolExecutionEnd(name: "shell", output: #"{"ok":true}"#))
      ) == .toolInvocationCompleted(name: "shell", output: #"{"ok":true}"#))
    #expect(
      ScribeAgentEventMapper.map(.boundary(.turnStart(round: 2)))
        == .toolRoundStarted(round: 2))
    #expect(ScribeAgentEventMapper.map(.tool(.warning("careful"))) == .warning("careful"))
    #expect(ScribeAgentEventMapper.map(.tool(.invocation(name: "x", arguments: "y", output: "z"))) == nil)
    #expect(
      ScribeAgentEventMapper.map(.lifecycle(.usage(ScribeUsage(totalTokens: 7), tokensPerSecond: 3.25)))
        == .usage(ScribeUsageSnapshot(totalTokens: 7, tokensPerSecond: 3.25)))
    #expect(ScribeAgentEventMapper.map(.lifecycle(.interrupted)) == .interrupted)
    #expect(
      ScribeAgentEventMapper.map(.lifecycle(.recovered(reason: "compacted")))
        == .recovered(reason: "compacted"))
    #expect(
      ScribeAgentEventMapper.map(
        .lifecycle(.retrying(attempt: 2, maxRetries: 3, delay: .milliseconds(1500), reason: "rate limited"))
      ) == .retrying(attempt: 2, maxAttempts: 3, delaySeconds: 1.5, reason: "rate limited"))
  }

  @Test func lifecycleErrorsMapToNonTerminalErrorEvents() {
    let mapped = ScribeAgentEventMapper.map(.lifecycle(.error(.generic("boom"))))
    #expect(mapped == .error("boom"))
    #expect(!(mapped?.isTerminal ?? true))
  }

  @Test func nonSemanticBoundariesAreDropped() {
    #expect(ScribeAgentEventMapper.map(.boundary(.agentStart)) == nil)
    #expect(ScribeAgentEventMapper.map(.boundary(.turnEnd(round: 1, outcome: .completed))) == nil)
    #expect(ScribeAgentEventMapper.map(.boundary(.messageStart(role: .user, round: 1))) == nil)
    #expect(ScribeAgentEventMapper.map(.boundary(.messageEnd(role: .user, round: 1))) == nil)
  }

  @Test func turnOutcomesMapToCodableOutcomes() {
    #expect(ScribeAgentEventMapper.map(TurnOutcome.completed) == .completed)
    #expect(ScribeAgentEventMapper.map(TurnOutcome.incomplete(reason: "budget")) == .incomplete(reason: "budget"))
    #expect(ScribeAgentEventMapper.map(TurnOutcome.interrupted) == .interrupted)
    #expect(ScribeAgentEventMapper.map(TurnOutcome.toolRoundLimit(rounds: 9)) == .toolRoundLimit(rounds: 9))
    #expect(ScribeAgentEventMapper.map(TurnOutcome.error("down")) == .error("down"))
  }

  @Test func failureMessagesAreDisplaySafe() {
    let scribeMessage = ScribeAgentEventMapper.failureMessage(for: ScribeError.generic("kaboom"))
    #expect(scribeMessage.contains("kaboom"))

    struct CustomError: Error, CustomStringConvertible {
      var description: String { "custom failure" }
    }
    let custom = ScribeAgentEventMapper.failureMessage(for: CustomError())
    #expect(!custom.isEmpty)
  }
}
