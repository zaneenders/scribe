import Foundation
import Synchronization

/// Read-only view of an abort source.  Consumers (the agent loop, tool
/// registry, stream processor — anything that needs to *react* to abort)
/// take this protocol instead of the concrete `AbortNotifier` class so
/// they don't pick up the trigger surface (`request()` / `clear()`) by
/// accident, and so test fakes can supply their own observer without
/// subclassing.
///
/// Public so embedders can implement custom ``ToolExecutor``s that
/// participate in the same cooperative-cancellation protocol the agent
/// loop and built-in tools use.
///
/// Two methods cover both polling and event-driven consumption:
/// - `isAborted()` — synchronous snapshot, called at loop checkpoints.
/// - `signals()` — `AsyncStream<Void>` that yields once on each abort
///   request, used by the tool registry's watch task for zero-latency
///   wake-up. Late subscribers see the in-flight abort flag immediately.
public protocol AbortObserver: Sendable {
  func isAborted() -> Bool
  func signals() -> AsyncStream<Void>
}


extension AbortObserver {
  /// Race `operation` against this abort observer. If abort fires before
  /// `operation` completes, the operation task is cancelled — which
  /// propagates down to blocking I/O (e.g. AsyncHTTPClient tears down the
  /// connection) — and `AgentTurnInterruptedError` is thrown.
  ///
  /// When `signals()` ends without yielding (e.g. test fakes that synthesise
  /// an empty stream), the watcher suspends in `Task.sleep` until the parent
  /// cancels it, so it never preempts the operation spuriously.
  func race<T: Sendable>(
    _ operation: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
      group.addTask { try await operation() }
      group.addTask { [self] in
        for await _ in self.signals() {
          if self.isAborted() { throw AgentTurnInterruptedError() }
        }
        // Stream ended without an abort. Suspend until the parent cancels
        // us (operation already won) rather than throwing CancellationError,
        // which would preempt the operation when a test fake yields an empty
        // stream.
        try await Task.sleep(for: .seconds(86_400))
        throw CancellationError()
      }
      let winner = try await group.next()!
      group.cancelAll()
      return winner
    }
  }
}


internal final class AbortNotifier: AbortObserver, Sendable {

  private struct State {
    var isSet = false
    var nextID: UInt64 = 0
    var continuations: [UInt64: AsyncStream<Void>.Continuation] = [:]
  }

  private let state = Mutex(State())

  init() {}

  func isAborted() -> Bool {
    state.withLock { $0.isSet }
  }

  func request() {
    let conts: [AsyncStream<Void>.Continuation] = state.withLock { s in
      s.isSet = true
      return Array(s.continuations.values)
    }
    for c in conts { c.yield() }
  }

  func clear() {
    state.withLock { $0.isSet = false }
  }

  func signals() -> AsyncStream<Void> {
    AsyncStream { continuation in
      let id: UInt64 = state.withLock { s in
        let id = s.nextID
        s.nextID &+= 1
        s.continuations[id] = continuation
        if s.isSet {
          continuation.yield()
        }
        return id
      }
      continuation.onTermination = { [weak self] _ in
        guard let self else { return }
        self.state.withLock { _ = $0.continuations.removeValue(forKey: id) }
      }
    }
  }
}
