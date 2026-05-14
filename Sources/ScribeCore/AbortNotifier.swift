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
