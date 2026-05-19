import Foundation
import Logging
import ScribeCore
import Synchronization
import Testing

@testable import ScribeCLI

// MARK: - ChatCoordinator tests

/// Tests for the `ChatCoordinator` actor — verifies initialization, event
/// emission patterns, and lifecycle without needing a real ScribeAgent.
@Suite
struct ChatCoordinatorTests {

  private let log = Logger(label: "test.chat-coordinator")

  // MARK: - Initialization

  @Test func coordinatorInitialization() async throws {
    let (lines, _) = AsyncStream<String>.makeStream()
    let events: Mutex<[HostEvent]> = Mutex([])

    let coordinator = try ChatCoordinator(
      configuration: .testValue,
      systemPrompt: "test prompt",
      resumeSnapshot: [],
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

  /// `interrupt()` is a `nonisolated` no-op when no turn is in flight —
  /// the host calls it freely from its Ctrl+C handler, including before
  /// `run()` has started consuming lines. With eager agent construction
  /// the agent always exists, but the agent's notifier is `clear()`-ed at
  /// the top of every prompt, so an `abort()` issued before/between
  /// prompts is dropped on the next `prompt()`.
  @Test func interruptBeforeRunIsNoOp() async throws {
    let (lines, _) = AsyncStream<String>.makeStream()
    let events: Mutex<[HostEvent]> = Mutex([])
    let coordinator = try ChatCoordinator(
      configuration: .testValue,
      systemPrompt: "test prompt",
      resumeSnapshot: [],
      log: log,
      enqueue: { event in events.withLock { $0.append(event) } },
      persistURL: URL(fileURLWithPath: "/tmp/test"),
      sessionId: UUID(),
      sessionCreatedAt: Date(),
      lines: lines
    )
    // Should not crash, throw, or block.
    coordinator.interrupt()
    #expect(events.withLock { $0.isEmpty })
  }

  /// A resume snapshot that doesn't lead with a system message is malformed;
  /// `init` should reject it rather than letting the bad state reach the
  /// agent loop.
  @Test func coordinatorRejectsCorruptResumeSnapshot() async {
    let (lines, _) = AsyncStream<String>.makeStream()
    let events: Mutex<[HostEvent]> = Mutex([])
    let badSnapshot: [ScribeMessage] = [
      ScribeMessage(role: .user, content: "no system message in front")
    ]
    do {
      _ = try ChatCoordinator(
        configuration: .testValue,
        systemPrompt: "test prompt",
        resumeSnapshot: badSnapshot,
        log: log,
        enqueue: { event in events.withLock { $0.append(event) } },
        persistURL: URL(fileURLWithPath: "/tmp/test"),
        sessionId: UUID(),
        sessionCreatedAt: Date(),
        lines: lines
      )
      Issue.record("Expected ScribeError.sessionCorrupted")
    } catch let error as ScribeError {
      if case .sessionCorrupted = error {
        // expected
      } else {
        Issue.record("Wrong ScribeError variant: \(error)")
      }
    } catch {
      Issue.record("Wrong error type: \(error)")
    }
  }

  // (`AbortNotifier` itself is tested directly in
  // `ScribeCoreTests/AbortNotifierTests` — fresh state, set, clear,
  // late subscribers, and multi-subscriber broadcast all live there.
  // Coordinator-level tests focus on the `interrupt()` API surface.)
}

// MARK: - Test helpers

extension ScribeConfig {
  static let testValue = ScribeConfig(
    agentModel: "test-model",
    contextWindow: 4000,
    contextWindowThreshold: 0.75,
    serverURL: "https://test.example.com",
    apiKey: "test-token",
    workingDirectory: "/tmp",
    reasoningEnabled: false
  )
}
