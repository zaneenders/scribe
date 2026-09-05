import Foundation
import Logging
import SystemPackage
import Testing

@testable import ScribeCore

@Suite
struct AbortNotifierTests {

  @Test func freshNotifierIsNotAborted() {
    let n = AbortNotifier()
    #expect(n.isAborted() == false)
  }

  @Test func requestSetsTheFlag() {
    let n = AbortNotifier()
    n.request()
    #expect(n.isAborted() == true)
  }

  @Test func clearResetsTheFlag() {
    let n = AbortNotifier()
    n.request()
    n.clear()
    #expect(n.isAborted() == false)
  }

  @Test func subscriberWakesOnRequest() async throws {
    let n = AbortNotifier()
    let stream = n.signals()

    let waiter = Task<Bool, Never> {
      var iter = stream.makeAsyncIterator()
      _ = await iter.next()
      return true
    }

    try await Task.sleep(for: .milliseconds(20))
    n.request()
    let woke = await waiter.value
    #expect(woke == true)
    #expect(n.isAborted() == true)
  }

  @Test func lateSubscriberSeesAlreadyRequestedAbort() async {
    let n = AbortNotifier()
    n.request()
    let stream = n.signals()

    var iter = stream.makeAsyncIterator()
    let value: Void? = await iter.next()
    #expect(value != nil)
  }

  @Test func multipleSubscribersAllWakeOnSingleRequest() async throws {
    let n = AbortNotifier()
    let s1 = n.signals()
    let s2 = n.signals()
    let s3 = n.signals()

    async let woke1: Bool = {
      var i = s1.makeAsyncIterator()
      _ = await i.next()
      return true
    }()
    async let woke2: Bool = {
      var i = s2.makeAsyncIterator()
      _ = await i.next()
      return true
    }()
    async let woke3: Bool = {
      var i = s3.makeAsyncIterator()
      _ = await i.next()
      return true
    }()

    try await Task.sleep(for: .milliseconds(20))
    n.request()

    let results = await (woke1, woke2, woke3)
    #expect(results.0 == true)
    #expect(results.1 == true)
    #expect(results.2 == true)
  }

  @Test(.timeLimit(.minutes(1)))
  func toolRegistryWakesPromptlyOnNotifierRequest() async throws {
    let registry = ToolRegistry(tools: [SleepyTool()], logger: toolRunnerTestLogger)
    let notifier = AbortNotifier()
    let outcomes = AsyncStream<AbortRaceOutcome>.makeStream()

    let toolTask = Task {
      do {
        _ = try await registry.run(
          name: "sleepy",
          arguments: "{}",
          workingDirectory: FilePath("/tmp"),
          logger: toolRunnerTestLogger,
          abortObserver: notifier)
        outcomes.continuation.yield(.unexpectedSuccess)
      } catch is AgentTurnInterruptedError {
        outcomes.continuation.yield(.interrupted(.now))
      } catch {
        outcomes.continuation.yield(.unexpectedError(String(describing: error)))
      }
    }

    try await Task.sleep(for: .milliseconds(50))
    let requestedAt = ContinuousClock.now
    notifier.request()

    let timeoutTask = Task {
      do {
        try await Task.sleep(for: .seconds(2))
        outcomes.continuation.yield(.timeout)
      } catch {
        // The tool completed first and cancelled this deadline.
      }
    }

    var iterator = outcomes.stream.makeAsyncIterator()
    let outcome = try #require(await iterator.next())
    toolTask.cancel()
    timeoutTask.cancel()
    outcomes.continuation.finish()

    switch outcome {
    case .interrupted(let interruptedAt):
      let latency = requestedAt.duration(to: interruptedAt)
      #expect(
        latency < .milliseconds(500),
        "event-driven abort should land well under 500 ms; took \(latency)")
    case .unexpectedSuccess:
      Issue.record("Expected AgentTurnInterruptedError, but the tool completed")
    case .unexpectedError(let error):
      Issue.record("Expected AgentTurnInterruptedError, got \(error)")
    case .timeout:
      Issue.record("Tool registry did not react to the abort within 2 seconds")
    }
  }
}

private enum AbortRaceOutcome: Sendable {
  case interrupted(ContinuousClock.Instant)
  case unexpectedSuccess
  case unexpectedError(String)
  case timeout
}

private struct SleepyTool: ScribeTool {
  static let name = "sleepy"
  static let description = "Sleeps until cancelled."
  static let parameters: [ScribeToolParameter] = []
  static let promptHint: String? = nil

  struct Output: Encodable { let ok: Bool }

  func run(arguments: String, workingDirectory: FilePath, logger: Logger) async throws -> Encodable {
    _ = logger
    try await Task.sleep(for: .seconds(60))
    return Output(ok: true)
  }
}
