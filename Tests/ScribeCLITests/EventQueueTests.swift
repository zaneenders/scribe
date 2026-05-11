@testable import ScribeCLI
import Testing

// MARK: - EventQueue tests

/// Tests for the standalone `EventQueue` — verifies thread-safe enqueue/drain
/// semantics without any Slate or @MainActor dependency.
@Suite
struct EventQueueTests {

  @Test func emptyDrainReturnsEmpty() {
    let q = EventQueue()
    #expect(q.drain().isEmpty)
  }

  @Test func singleEnqueueDrainRoundTrip() {
    let q = EventQueue()
    q.enqueue(.coordinatorFinished)
    let events = q.drain()
    #expect(events.count == 1)
    #expect(events.first == .coordinatorFinished)
  }

  @Test func drainClearsTheQueue() {
    let q = EventQueue()
    q.enqueue(.modelTurnRunning(true))
    _ = q.drain()
    #expect(q.drain().isEmpty)
  }

  @Test func multipleEnqueuesDrainInOrder() {
    let q = EventQueue()
    q.enqueue(.modelTurnRunning(true))
    q.enqueue(.transcript(.userSubmitted("hello")))
    q.enqueue(.modelTurnRunning(false))
    q.enqueue(.coordinatorFinished)

    let events = q.drain()
    #expect(events.count == 4)
    guard events.count == 4 else { return }
    #expect(events[0] == .modelTurnRunning(true))
    #expect(events[2] == .modelTurnRunning(false))
    #expect(events[3] == .coordinatorFinished)
  }

  @Test func concurrentEnqueuesDrainAll() async {
    let q = EventQueue()
    await withTaskGroup(of: Void.self) { group in
      for i in 0..<100 {
        group.addTask {
          q.enqueue(.modelTurnRunning(i % 2 == 0))
        }
      }
    }
    let events = q.drain()
    #expect(events.count == 100)
  }

  @Test func drainIsAtomic() async {
    let q = EventQueue()

    // Pre-fill
    for i in 0..<50 {
      q.enqueue(.modelTurnRunning(i % 2 == 0))
    }

    // Concurrently drain and enqueue more
    let drained = await withTaskGroup(of: [HostEvent].self) { group -> [HostEvent] in
      group.addTask {
        let events = q.drain()
        return events
      }
      group.addTask {
        for i in 0..<50 {
          q.enqueue(.modelTurnRunning(i % 2 == 0))
        }
        return []
      }
      // The drainer and enqueuer race; one drain wins the pre-filled events.
      // The drainer's return value plus subsequent drain should total 100.
      var allDrained = [HostEvent]()
      for await result in group {
        allDrained.append(contentsOf: result)
      }
      return allDrained
    }

    let remaining = q.drain()
    let total = drained.count + remaining.count
    #expect(total == 100)
  }
}
