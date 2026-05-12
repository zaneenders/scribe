import Foundation
import Synchronization

public final class AbortNotifier: Sendable {

  private struct State {
    var isSet = false
    var nextID: UInt64 = 0
    var continuations: [UInt64: AsyncStream<Void>.Continuation] = [:]
  }

  private let state = Mutex(State())

  public init() {}

  public func isAborted() -> Bool {
    state.withLock { $0.isSet }
  }

  public func request() {
    let conts: [AsyncStream<Void>.Continuation] = state.withLock { s in
      s.isSet = true
      return Array(s.continuations.values)
    }
    for c in conts { c.yield() }
  }

  public func clear() {
    state.withLock { $0.isSet = false }
  }

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
