import Foundation
import Logging
import ScribeCore
import SystemPackage
import Synchronization
import Testing

@testable import ScribeCLI

@Suite
struct ChatCoordinatorTests {

  private let logger = Logger(label: "test.chat-coordinator")

  @Test func coordinatorInitialization() async throws {
    let (lines, _) = AsyncStream<String>.makeStream()
    let events: Mutex<[HostEvent]> = Mutex([])
    let harness = try await makeTestHarness()

    let coordinator = ChatCoordinator(
      harness: harness,
      logger: logger,
      enqueue: { event in events.withLock { $0.append(event) } },
      lines: lines
    )
    _ = coordinator
  }

  @Test func interruptBeforeRunIsNoOp() async throws {
    let (lines, _) = AsyncStream<String>.makeStream()
    let events: Mutex<[HostEvent]> = Mutex([])
    let harness = try await makeTestHarness()
    let coordinator = ChatCoordinator(
      harness: harness,
      logger: logger,
      enqueue: { event in events.withLock { $0.append(event) } },
      lines: lines
    )
    coordinator.interrupt()
    #expect(events.withLock { $0.isEmpty })
  }

  private func makeTestHarness() async throws -> SessionHarness {
    let sessionId = UUID()
    let document = SessionDocument(
      sessionId: sessionId,
      directory: FilePath("/in-memory/\(sessionId.uuidString)"),
      logger: logger
    )
    return try SessionHarness(
      configuration: .testValue,
      document: consume document,
      persister: InMemorySessionPersister(),
      logger: logger
    )
  }
}

private extension ScribeConfig {
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
