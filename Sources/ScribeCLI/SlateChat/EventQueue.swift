import Synchronization

// MARK: - EventQueue

/// Thread-safe queue for `HostEvent` values — decouples the coordinator task
/// (which produces events) from the `@MainActor` host (which drains them).
///
/// Extracted from `SlateChatHost` so it can be tested independently.
final class EventQueue: Sendable {
  private let events: Mutex<[HostEvent]> = Mutex([])

  func enqueue(_ event: HostEvent) {
    events.withLock { $0.append(event) }
  }

  func drain() -> [HostEvent] {
    events.withLock {
      let copy = $0
      $0 = []
      return copy
    }
  }
}
