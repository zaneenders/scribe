import Foundation
import Synchronization

// MARK: - AbortNotifier

/// A multi-consumer event source for "should abort" signals.
///
/// Pairs cleanly with the existing `shouldAbortTurn: () -> Bool` synchronous
/// check used throughout `ScribeCore`: callers that want **event-driven**
/// abort wakeups (zero-latency, no polling) hand a notifier to
/// `AgentRunOptions.abortNotifier` *and* keep their synchronous
/// `shouldAbortTurn` closure consistent with it. Subscribers wake on every
/// `request()` and re-check the synchronous closure to decide whether to
/// actually throw `AgentTurnInterruptedError`.
///
/// Each call to `signals()` returns a fresh, single-consumer
/// `AsyncStream<Void>`; multiple concurrent consumers are supported (each
/// gets its own stream, registered against the notifier's internal table).
/// If `request()` was already called and not subsequently cleared, freshly
/// minted streams yield once immediately so late subscribers can't miss an
/// already-set abort.
///
/// ## Lifecycle
///
/// - `clear()` resets the internal flag (typically called at the start of
///   each new turn) but keeps existing subscriptions.
/// - When a subscriber's iterator is dropped or its task is cancelled, the
///   continuation's termination handler removes the entry from the internal
///   table. Long-lived notifiers therefore don't accumulate dead
///   subscriptions across many turns.
///
/// ## Example
///
/// ```swift
/// let notifier = AbortNotifier()
/// let options = AgentRunOptions(
///   shouldAbortTurn: { notifier.isAborted() },
///   abortNotifier: notifier)
/// // From a Ctrl+C handler:
/// notifier.request()
/// ```
public final class AbortNotifier: Sendable {

  private struct State {
    var isSet = false
    var nextID: UInt64 = 0
    var continuations: [UInt64: AsyncStream<Void>.Continuation] = [:]
  }

  private let state = Mutex(State())

  public init() {}

  /// Whether `request()` has been called since the last `clear()`.
  public func isAborted() -> Bool {
    state.withLock { $0.isSet }
  }

  /// Signal abort to all current subscribers and set the flag.
  ///
  /// Future `signals()` calls will yield once immediately while the flag
  /// remains set, so late subscribers don't miss an in-flight abort.
  public func request() {
    let conts: [AsyncStream<Void>.Continuation] = state.withLock { s in
      s.isSet = true
      return Array(s.continuations.values)
    }
    for c in conts { c.yield() }
  }

  /// Clear the internal flag without disturbing existing subscriptions.
  public func clear() {
    state.withLock { $0.isSet = false }
  }

  /// A new `AsyncStream<Void>` that yields each time `request()` is called.
  ///
  /// If the notifier is already in the aborted state, the stream yields
  /// once immediately on first iteration so subscribers can't miss an
  /// already-set abort.
  public func signals() -> AsyncStream<Void> {
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
