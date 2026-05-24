import Foundation
import Logging
import ScribeCore
import SystemPackage
import Synchronization
import Testing

@testable import ScribeCLI

// MARK: - ChatCoordinator tests

/// Tests for the `ChatCoordinator` actor — verifies initialization and the
/// `interrupt()` surface without needing a real ScribeAgent. Persistence and
/// session-level concerns moved to ``SessionDocument`` / ``FileSessionPersister``
/// and are covered by ``SessionDocumentTests`` and host-level integration
/// tests.
@Suite
struct ChatCoordinatorTests {

  private let logger = Logger(label: "test.chat-coordinator")

  private func makeDocument(
    initial: [ScribeMessage] = [ScribeMessage(role: .system, content: "sys")]
  ) -> SessionDocument {
    SessionDocument(
      sessionId: UUID(),
      directory: FilePath("/in-memory"),
      initialMessages: initial,
      persister: InMemorySessionPersister(),
      logger: logger
    )
  }

  // MARK: - Initialization

  @Test func coordinatorInitialization() async throws {
    let (lines, _) = AsyncStream<String>.makeStream()
    let events: Mutex<[HostEvent]> = Mutex([])
    let document = makeDocument()

    let coordinator = try ChatCoordinator(
      configuration: .testValue,
      logger: logger,
      enqueue: { event in events.withLock { $0.append(event) } },
      document: document,
      lines: lines
    )
    // Coordinator should initialize without crashing.
    _ = coordinator
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
    let document = makeDocument()
    let coordinator = try ChatCoordinator(
      configuration: .testValue,
      logger: logger,
      enqueue: { event in events.withLock { $0.append(event) } },
      document: document,
      lines: lines
    )
    // Should not crash, throw, or block.
    coordinator.interrupt()
    #expect(events.withLock { $0.isEmpty })
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
    workingDirectory: "/tmp",
    reasoningEnabled: nil
  )
}
