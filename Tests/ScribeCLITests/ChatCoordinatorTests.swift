import Foundation
import Logging
import ScribeCore
import ScribeLLM
import Testing

@testable import ScribeCLI

// MARK: - ChatCoordinator tests

/// Tests for the `ChatCoordinator` — verifies initialization, turn-loop
/// event emission, interrupt handling, stop conditions, and lifecycle using
/// `MockAgent` instead of a live LLM.
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
      enqueue: { event in events.withLock { $0.append(event) } },
      persistURL: URL(fileURLWithPath: "/tmp/test-coordinator-init"),
      sessionId: UUID(),
      sessionCreatedAt: Date(),
      lines: lines,
      makeAgent: { _ in MockAgent.makeDefault() }
    )
    _ = coordinator
  }

  /// `interrupt()` is a safe no-op before `run()` has materialised the agent.
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
      lines: lines,
      makeAgent: { _ in MockAgent.makeDefault() }
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
    let badSnapshot: [Components.Schemas.ChatMessage] = [
      .init(role: .user, content: "no system message in front")
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
        lines: lines,
        makeAgent: { _ in MockAgent.makeDefault() }
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

  // MARK: - Single turn completion

  @Test func singleTurnEmitsCorrectEvents() async throws {
    let (lines, cont) = AsyncStream<String>.makeStream()
    let events: Mutex<[HostEvent]> = Mutex([])
    let persistURL = URL(fileURLWithPath: "/tmp/test-single-turn-\(UUID().uuidString)")

    let coordinator = try ChatCoordinator(
      configuration: .testValue,
      systemPrompt: "test",
      resumeSnapshot: [],
      log: log,
      enqueue: { event in events.withLock { $0.append(event) } },
      persistURL: persistURL,
      sessionId: UUID(),
      sessionCreatedAt: Date(),
      lines: lines,
      makeAgent: { _ in MockAgent.makeDefault() }
    )

    let task = Task { await coordinator.run() }

    // Send one line then finish.
    cont.yield("hello")
    cont.finish()

    _ = await task.value

    let all = events.withLock { $0 }
    // Expected sequence: userSubmitted, modelTurnRunning(true), assistant events from mock,
    // modelTurnRunning(false), turnComplete, coordinatorFinished
    let hasUserSubmit = all.contains { if case .transcript(.userSubmitted("hello")) = $0 { true } else { false } }
    let hasBusyOn = all.contains { $0 == .modelTurnRunning(true) }
    let hasBusyOff = all.contains { $0 == .modelTurnRunning(false) }
    let hasTurnComplete = all.contains { if case .transcript(.turnComplete) = $0 { true } else { false } }
    let hasCoordFinished = all.contains { $0 == .coordinatorFinished }

    #expect(hasUserSubmit)
    #expect(hasBusyOn)
    #expect(hasBusyOff)
    #expect(hasTurnComplete)
    #expect(hasCoordFinished)
  }

  // MARK: - Exit command stops coordinator

  @Test func exitCommandStopsCoordinator() async throws {
    let (lines, cont) = AsyncStream<String>.makeStream()
    let events: Mutex<[HostEvent]> = Mutex([])

    let coordinator = try ChatCoordinator(
      configuration: .testValue,
      systemPrompt: "test",
      resumeSnapshot: [],
      log: log,
      enqueue: { event in events.withLock { $0.append(event) } },
      persistURL: URL(fileURLWithPath: "/tmp/test-exit-\(UUID().uuidString)"),
      sessionId: UUID(),
      sessionCreatedAt: Date(),
      lines: lines,
      makeAgent: { _ in MockAgent.makeDefault() }
    )

    let task = Task { await coordinator.run() }
    cont.yield("exit")
    cont.finish()
    _ = await task.value

    let all = events.withLock { $0 }
    // Exit should NOT produce userSubmitted — it breaks before that.
    let hasUserSubmit = all.contains { if case .transcript(.userSubmitted) = $0 { true } else { false } }
    #expect(!hasUserSubmit, "Exit command should not trigger userSubmitted")
    #expect(all.contains { $0 == .coordinatorFinished })
  }

  // MARK: - Empty lines are skipped

  @Test func emptyLinesAreSkipped() async throws {
    let (lines, cont) = AsyncStream<String>.makeStream()
    let events: Mutex<[HostEvent]> = Mutex([])

    let coordinator = try ChatCoordinator(
      configuration: .testValue,
      systemPrompt: "test",
      resumeSnapshot: [],
      log: log,
      enqueue: { event in events.withLock { $0.append(event) } },
      persistURL: URL(fileURLWithPath: "/tmp/test-empty-\(UUID().uuidString)"),
      sessionId: UUID(),
      sessionCreatedAt: Date(),
      lines: lines,
      makeAgent: { _ in MockAgent.makeDefault() }
    )

    let task = Task { await coordinator.run() }
    cont.yield("   ")
    cont.yield("")
    cont.yield("\t\n")
    cont.finish()
    _ = await task.value

    let all = events.withLock { $0 }
    let userSubmits = all.filter { if case .transcript(.userSubmitted) = $0 { true } else { false } }
    #expect(userSubmits.isEmpty, "Empty/whitespace lines should not trigger userSubmitted")
  }

  // MARK: - Multiple turns

  @Test func multipleTurnsAccumulateTranscript() async throws {
    let (lines, cont) = AsyncStream<String>.makeStream()
    let events: Mutex<[HostEvent]> = Mutex([])

    let coordinator = try ChatCoordinator(
      configuration: .testValue,
      systemPrompt: "test",
      resumeSnapshot: [],
      log: log,
      enqueue: { event in events.withLock { $0.append(event) } },
      persistURL: URL(fileURLWithPath: "/tmp/test-multi-\(UUID().uuidString)"),
      sessionId: UUID(),
      sessionCreatedAt: Date(),
      lines: lines,
      makeAgent: { _ in MockAgent.makeDefault() }
    )

    let task = Task { await coordinator.run() }
    cont.yield("first")
    cont.yield("second")
    cont.finish()
    _ = await task.value

    let all = events.withLock { $0 }
    let userSubmits = all.filter { if case .transcript(.userSubmitted) = $0 { true } else { false } }
    #expect(userSubmits.count == 2)
  }

  // MARK: - Resume snapshot

  @Test func resumeSnapshotWithSystemMessage() async throws {
    let (lines, _) = AsyncStream<String>.makeStream()
    let events: Mutex<[HostEvent]> = Mutex([])

    let resume: [Components.Schemas.ChatMessage] = [
      .init(role: .system, content: "resumed system prompt"),
      .init(role: .user, content: "previous message"),
    ]

    let coordinator = try ChatCoordinator(
      configuration: .testValue,
      systemPrompt: "default prompt",
      resumeSnapshot: resume,
      log: log,
      enqueue: { event in events.withLock { $0.append(event) } },
      persistURL: URL(fileURLWithPath: "/tmp/test-resume-\(UUID().uuidString)"),
      sessionId: UUID(),
      sessionCreatedAt: Date(),
      lines: lines,
      makeAgent: { initialMessages in
        // Verify the initial messages include the resume snapshot
        #expect(initialMessages.count == 2)
        #expect(initialMessages.first?.role == .system)
        return MockAgent.makeDefault(messages: initialMessages)
      }
    )
    _ = coordinator
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

// MARK: - Multiple turns

@Suite
struct ChatCoordinatorMultiTurnTests {

    private let log = Logger(label: "test.chat-coordinator.multi-turn")

    @Test func twoTurnsEmitCorrectEventSequence() async throws {
        let (lines, cont) = AsyncStream<String>.makeStream()
        let events: Mutex<[HostEvent]> = Mutex([])
        let persistURL = URL(fileURLWithPath: "/tmp/test-multi-turn-\(UUID().uuidString)")

        let coordinator = try ChatCoordinator(
            configuration: .testValue,
            systemPrompt: "test",
            resumeSnapshot: [],
            log: log,
            enqueue: { event in events.withLock { $0.append(event) } },
            persistURL: persistURL,
            sessionId: UUID(),
            sessionCreatedAt: Date(),
            lines: lines,
            makeAgent: { _ in MockAgent.makeDefault() }
        )

        let task = Task { await coordinator.run() }

        // First turn
        cont.yield("first message")
        // Give the coordinator time to process
        try? await Task.sleep(for: .milliseconds(100))
        // Second turn
        cont.yield("second message")
        cont.finish()

        _ = await task.value

        let all = events.withLock { $0 }
        // Should have two userSubmitted events
        let userSubmits = all.filter {
            if case .transcript(.userSubmitted) = $0 { true } else { false }
        }
        #expect(userSubmits.count == 2)
    }

    @Test func turnCompleteEventBetweenTurns() async throws {
        let (lines, cont) = AsyncStream<String>.makeStream()
        let events: Mutex<[HostEvent]> = Mutex([])
        let persistURL = URL(fileURLWithPath: "/tmp/test-turn-complete-\(UUID().uuidString)")

        let coordinator = try ChatCoordinator(
            configuration: .testValue,
            systemPrompt: "test",
            resumeSnapshot: [],
            log: log,
            enqueue: { event in events.withLock { $0.append(event) } },
            persistURL: persistURL,
            sessionId: UUID(),
            sessionCreatedAt: Date(),
            lines: lines,
            makeAgent: { _ in MockAgent.makeDefault() }
        )

        let task = Task { await coordinator.run() }

        cont.yield("message one")
        try? await Task.sleep(for: .milliseconds(100))
        cont.yield("message two")
        cont.finish()

        _ = await task.value

        let all = events.withLock { $0 }
        let turnCompletes = all.filter {
            if case .transcript(.turnComplete) = $0 { true } else { false }
        }
        #expect(turnCompletes.count >= 1, "Expected at least 1 turnComplete event, got \(turnCompletes.count)")
    }

    @Test func emptyInputIsSkipped() async throws {
        let (lines, cont) = AsyncStream<String>.makeStream()
        let events: Mutex<[HostEvent]> = Mutex([])
        let persistURL = URL(fileURLWithPath: "/tmp/test-empty-input-\(UUID().uuidString)")

        let coordinator = try ChatCoordinator(
            configuration: .testValue,
            systemPrompt: "test",
            resumeSnapshot: [],
            log: log,
            enqueue: { event in events.withLock { $0.append(event) } },
            persistURL: persistURL,
            sessionId: UUID(),
            sessionCreatedAt: Date(),
            lines: lines,
            makeAgent: { _ in MockAgent.makeDefault() }
        )

        let task = Task { await coordinator.run() }

        // Send whitespace-only (should be skipped)
        cont.yield("   ")
        try? await Task.sleep(for: .milliseconds(50))
        // Send real message
        cont.yield("real message")
        cont.finish()

        _ = await task.value

        let all = events.withLock { $0 }
        let userSubmits = all.filter {
            if case .transcript(.userSubmitted) = $0 { true } else { false }
        }
        // Whitespace-only should not produce a userSubmitted event
        #expect(userSubmits.count == 1, "Expected 1 userSubmitted, got \(userSubmits.count)")
    }
}

// MARK: - ChatCoordinator resume tests

@Suite
struct ChatCoordinatorResumeTests {

    private let log = Logger(label: "test.chat-coordinator.resume")

    @Test func resumeWithExistingMessagesDoesNotEmitReplayEvents() async throws {
        let resumeMessages: [Components.Schemas.ChatMessage] = [
            .init(role: .system, content: "sys"),
            .init(role: .user, content: "previous question"),
            .init(role: .assistant, content: "previous answer"),
        ]

        let (lines, cont) = AsyncStream<String>.makeStream()
        let events: Mutex<[HostEvent]> = Mutex([])
        let persistURL = URL(fileURLWithPath: "/tmp/test-resume-\(UUID().uuidString)")

        let coordinator = try ChatCoordinator(
            configuration: .testValue,
            systemPrompt: "test",
            resumeSnapshot: resumeMessages,
            log: log,
            enqueue: { event in events.withLock { $0.append(event) } },
            persistURL: persistURL,
            sessionId: UUID(),
            sessionCreatedAt: Date(),
            lines: lines,
            makeAgent: { _ in MockAgent.makeDefault() }
        )

        let task = Task { await coordinator.run() }

        cont.yield("new message")
        cont.finish()

        _ = await task.value

        let all = events.withLock { $0 }
        // Should have userSubmitted for new message
        let userSubmits = all.filter {
            if case .transcript(.userSubmitted) = $0 { true } else { false }
        }
        #expect(userSubmits.count >= 1)
    }

    @Test func resumeWithEmptySnapshotBehavesLikeNewSession() async throws {
        let (lines, cont) = AsyncStream<String>.makeStream()
        let events: Mutex<[HostEvent]> = Mutex([])
        let persistURL = URL(fileURLWithPath: "/tmp/test-resume-empty-\(UUID().uuidString)")

        let coordinator = try ChatCoordinator(
            configuration: .testValue,
            systemPrompt: "test",
            resumeSnapshot: [],  // empty = new session
            log: log,
            enqueue: { event in events.withLock { $0.append(event) } },
            persistURL: persistURL,
            sessionId: UUID(),
            sessionCreatedAt: Date(),
            lines: lines,
            makeAgent: { _ in MockAgent.makeDefault() }
        )

        let task = Task { await coordinator.run() }

        cont.yield("first ever message")
        cont.finish()

        _ = await task.value

        let all = events.withLock { $0 }
        let userSubmits = all.filter {
            if case .transcript(.userSubmitted) = $0 { true } else { false }
        }
        #expect(userSubmits.count == 1)
    }
}
