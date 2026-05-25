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

      #expect(
        elapsed < .milliseconds(150),
        "event-driven abort should land well under 150 ms; took \(elapsed)")
    }
  }
}

private struct NotifierWakeTimeoutError: Error {}

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
