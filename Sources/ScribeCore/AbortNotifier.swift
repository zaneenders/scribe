import Foundation
import Synchronization

public protocol AbortObserver: Sendable {
  func isAborted() -> Bool
  func signals() -> AsyncStream<Void>
}

extension AbortObserver {

  func race<T: Sendable>(
    _ operation: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
      group.addTask { try await operation() }
      group.addTask { [self] in
        for await _ in self.signals() {
          if self.isAborted() { throw AgentTurnInterruptedError() }
        }

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
