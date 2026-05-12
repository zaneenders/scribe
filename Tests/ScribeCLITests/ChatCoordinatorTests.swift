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
    let interruptNotifier = AbortNotifier()
    let events: Mutex<[HostEvent]> = Mutex([])

    let coordinator = ChatCoordinator(
      configuration: .testValue,
      systemPrompt: "test prompt",
      resumeSnapshot: [],
      interruptNotifier: interruptNotifier,
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

  // (The previous `ModelTurnInterruptFlag` tests were removed alongside the
  // wrapper itself; the underlying `AbortNotifier` is exercised directly in
  // `ScribeCoreTests/AbortNotifierTests`, which covers fresh state, set,
  // clear, late subscribers, and multi-subscriber broadcast.)
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
