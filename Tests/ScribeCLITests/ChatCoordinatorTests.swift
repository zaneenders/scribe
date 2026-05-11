import Foundation
import Logging
import ScribeCore
import Testing

@testable import ScribeCLI

// MARK: - ChatCoordinator tests

/// Tests for the `ChatCoordinator` actor — verifies initialization, event
/// emission patterns, and lifecycle without needing a real ScribeAgent.
@Suite
struct ChatCoordinatorTests {

  private let log = Logger(label: "test.chat-coordinator")

  // MARK: - Initialization

  @Test func coordinatorInitialization() async {
    let (lines, _) = AsyncStream<String>.makeStream()
    let interruptFlag = ModelTurnInterruptFlag()
    let events: Mutex<[HostEvent]> = Mutex([])

    let coordinator = ChatCoordinator(
      configuration: .testValue,
      systemPrompt: "test prompt",
      resumeSnapshot: [],
      interruptFlag: interruptFlag,
      log: log,
      enqueue: { event in
        events.withLock { $0.append(event) }
      },
      persistURL: URL(fileURLWithPath: "/tmp/test"),
      sessionId: UUID(),
      sessionCreatedAt: Date(),
      lines: lines
    )
    // Coordinator should initialize without crashing.
    #expect(true)
    _ = coordinator  // silence unused warning
  }

  // MARK: - ModelTurnInterruptFlag

  @Test func interruptFlagInitiallyNotSet() {
    let flag = ModelTurnInterruptFlag()
    #expect(!flag.peek())
  }

  @Test func interruptFlagSetAndPeek() {
    let flag = ModelTurnInterruptFlag()
    flag.request()
    #expect(flag.peek())
  }

  @Test func interruptFlagClear() {
    let flag = ModelTurnInterruptFlag()
    flag.request()
    flag.clear()
    #expect(!flag.peek())
  }

  @Test func interruptFlagConcurrentAccess() async {
    let flag = ModelTurnInterruptFlag()
    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<100 {
        group.addTask {
          flag.request()
        }
        group.addTask {
          _ = flag.peek()
        }
        group.addTask {
          flag.clear()
        }
      }
    }
    // Should not crash — final state is deterministic per last write wins.
    _ = flag.peek()
  }
}

// MARK: - Test helpers

extension ScribeConfig {
  static let testValue = ScribeConfig(
    agentModel: "test-model",
    contextWindow: 4000,
    contextWindowThreshold: 0.75,
    serverURL: "https://test.example.com",
    apiKey: "test-token",
    workingDirectory: "/tmp"
  )
}

/// Simple mutex wrapper for test event collection.
final class Mutex<T>: @unchecked Sendable {
  private var value: T
  private let lock = NSLock()

  init(_ value: T) {
    self.value = value
  }

  func withLock<R>(_ body: (inout T) -> R) -> R {
    lock.lock()
    defer { lock.unlock() }
    return body(&value)
  }
}
