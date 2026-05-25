import Foundation
import Logging
import ScribeCore
import SystemPackage
import Synchronization
import Testing

@testable import ScribeCLI


/// Tests for the `ChatCoordinator` — verifies initialization and the
/// `interrupt()` surface without needing a real ScribeAgent. Persistence
/// and session-level concerns now live on the host-owned ``SessionDocument``
/// and ``FileSessionPersister`` and are covered by ``SessionDocumentTests``
/// and host-level integration tests.
@Suite
struct ChatCoordinatorTests {

  private let logger = Logger(label: "test.chat-coordinator")

  /// Build the three closures the coordinator expects in lieu of a doc
  /// reference. Tests don't actually drive a turn, so the closures are
  /// all no-ops returning empty data.
  private static func noopDocClosures() -> (
    agentHistory: @MainActor @Sendable () -> [ScribeMessage],
    applyAppend: @MainActor @Sendable ([ScribeMessage]) async throws -> Void,
    documentCount: @MainActor @Sendable () -> Int
  ) {
    return (
      agentHistory: { [] },
      applyAppend: { _ in },
      documentCount: { 0 }
    )
  }


  @Test func coordinatorInitialization() async throws {
    let (lines, _) = AsyncStream<String>.makeStream()
    let events: Mutex<[HostEvent]> = Mutex([])
    let closures = Self.noopDocClosures()

    let coordinator = try ChatCoordinator(
      configuration: .testValue,
      logger: logger,
      enqueue: { event in events.withLock { $0.append(event) } },
      agentHistory: closures.agentHistory,
      applyAppend: closures.applyAppend,
      documentCount: closures.documentCount,
      lines: lines
    )
    // Coordinator should initialize without crashing.
    _ = coordinator
  }

  /// `interrupt()` is a no-op when no turn is in flight — the host calls
  /// it freely from its Ctrl+C handler, including before `run()` has
  /// started consuming lines. With eager agent construction the agent
  /// always exists, but the agent's notifier is cleared at the top of
  /// every turn, so an `abort()` issued before/between turns is dropped
  /// on the next `run()`.
  @Test func interruptBeforeRunIsNoOp() async throws {
    let (lines, _) = AsyncStream<String>.makeStream()
    let events: Mutex<[HostEvent]> = Mutex([])
    let closures = Self.noopDocClosures()
    let coordinator = try ChatCoordinator(
      configuration: .testValue,
      logger: logger,
      enqueue: { event in events.withLock { $0.append(event) } },
      agentHistory: closures.agentHistory,
      applyAppend: closures.applyAppend,
      documentCount: closures.documentCount,
      lines: lines
    )
    // Should not crash, throw, or block.
    coordinator.interrupt()
    #expect(events.withLock { $0.isEmpty })
  }
}


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
