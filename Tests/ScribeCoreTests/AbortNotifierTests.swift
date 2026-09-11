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

    n.request()

    let results = await (woke1, woke2, woke3)
    #expect(results.0 == true)
    #expect(results.1 == true)
    #expect(results.2 == true)
  }

  @Test(.timeLimit(.minutes(1)))
  func toolRegistryWakesPromptlyOnNotifierRequest() async throws {
    let readiness = TestReadiness()
    let registry = ToolRegistry(tools: [SleepyTool(readiness: readiness)], logger: toolRunnerTestLogger)
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
        outcomes.continuation.yield(.interrupted)
      } catch {
        outcomes.continuation.yield(.unexpectedError(String(describing: error)))
      }
    }

    defer { toolTask.cancel() }
    try await readiness.wait()
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
    case .interrupted:
      // Receiving this before the deadline proves the event-driven abort path
      // woke the registry. Avoid a sub-second scheduling assertion: heavily
      // loaded CI runners can pause the test task after the abort is delivered.
      break
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
  case interrupted
  case unexpectedSuccess
  case unexpectedError(String)
  case timeout
}

private struct SleepyTool: ScribeTool {
  let readiness: TestReadiness
  static let name = "sleepy"
  static let description = "Sleeps until cancelled."
  static let parameters: [ScribeToolParameter] = []
  static let promptHint: String? = nil

  struct Output: Encodable { let ok: Bool }

  func run(arguments: String, workingDirectory: FilePath, logger: Logger) async throws -> Encodable {
    _ = logger
    readiness.signal()
    try await Task.sleep(for: .seconds(60))
    return Output(ok: true)
  }
}
