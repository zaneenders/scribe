import SystemPackage
import Foundation
import Logging
import Testing

@testable import ScribeCore

@Suite
struct AbortNotifierTests {

  // MARK: - Primitive behaviour

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
      _ = await iter.next()  // suspends until request()
      return true
    }
    // Give the consumer a moment to start iterating.
    try await Task.sleep(for: .milliseconds(20))
    n.request()
    let woke = await waiter.value
    #expect(woke == true)
    #expect(n.isAborted() == true)
  }

  @Test func lateSubscriberSeesAlreadyRequestedAbort() async {
    let n = AbortNotifier()
    n.request()  // signal first…
    let stream = n.signals()  // …then subscribe

    var iter = stream.makeAsyncIterator()
    let value: Void? = await iter.next()  // must not hang
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

  // MARK: - ToolRegistry integration

  /// Confirms the event-driven abort path in `ToolRegistry.run` wakes the
  /// watch task essentially immediately. We use a tool that sleeps for a
  /// long time inside its run() body so the only way out is the watch task
  /// firing.
  @Test func toolRegistryWakesPromptlyOnNotifierRequest() async throws {
    let registry = ToolRegistry(tools: [SleepyTool()], logger: toolRunnerTestLogger)
    let notifier = AbortNotifier()

    let start = ContinuousClock.now
    do {
      _ = try await withThrowingTaskGroup(of: ToolResult.self) { group in
        group.addTask {
          try await registry.run(
            name: "sleepy",
            arguments: "{}",
            workingDirectory: FilePath("/tmp"),
            logger: toolRunnerTestLogger,
            abortObserver: notifier)
        }
        group.addTask {
          // Let the tool start, then signal abort.
          try await Task.sleep(for: .milliseconds(50))
          notifier.request()
          try await Task.sleep(for: .seconds(2))
          throw NotifierWakeTimeoutError()
        }
        defer { group.cancelAll() }
        return try await group.next()!
      }
      Issue.record("Expected AgentTurnInterruptedError")
    } catch is AgentTurnInterruptedError {
      let elapsed = start.duration(to: .now)
      // Generous bound: even on slow CI the wake should land in <100 ms.
      #expect(
        elapsed < .milliseconds(150),
        "event-driven abort should land well under 150 ms; took \(elapsed)")
    }
  }
}

private struct NotifierWakeTimeoutError: Error {}

/// Test tool that sleeps for a long time. Used to verify abort wakes happen
/// via the watch task (the tool itself never returns under the test timeout).
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
