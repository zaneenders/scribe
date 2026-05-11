import Foundation
import Logging
import ScribeCore
import ScribeLLM
import Testing

@testable import ScribeCLI

// MARK: - ChatCoordinator tests

/// Tests for the `ChatCoordinator` actor — verifies initialization, turn-loop
/// event emission, interrupt handling, stop conditions, and lifecycle using
/// `MockAgent` instead of a live LLM.
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
      enqueue: { event in events.withLock { $0.append(event) } },
      persistURL: URL(fileURLWithPath: "/tmp/test-coordinator-init"),
      sessionId: UUID(),
      sessionCreatedAt: Date(),
      lines: lines,
      makeAgent: { _ in MockAgent.makeDefault() }
    )
    _ = coordinator
  }

  // MARK: - Single turn completion

  @Test func singleTurnEmitsCorrectEvents() async {
    let (lines, cont) = AsyncStream<String>.makeStream()
    let interruptFlag = ModelTurnInterruptFlag()
    let events: Mutex<[HostEvent]> = Mutex([])
    let persistURL = URL(fileURLWithPath: "/tmp/test-single-turn-\(UUID().uuidString)")

    let coordinator = ChatCoordinator(
      configuration: .testValue,
      systemPrompt: "test",
      resumeSnapshot: [],
      interruptFlag: interruptFlag,
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

  @Test func exitCommandStopsCoordinator() async {
    let (lines, cont) = AsyncStream<String>.makeStream()
    let interruptFlag = ModelTurnInterruptFlag()
    let events: Mutex<[HostEvent]> = Mutex([])

    let coordinator = ChatCoordinator(
      configuration: .testValue,
      systemPrompt: "test",
      resumeSnapshot: [],
      interruptFlag: interruptFlag,
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

  @Test func emptyLinesAreSkipped() async {
    let (lines, cont) = AsyncStream<String>.makeStream()
    let interruptFlag = ModelTurnInterruptFlag()
    let events: Mutex<[HostEvent]> = Mutex([])

    let coordinator = ChatCoordinator(
      configuration: .testValue,
      systemPrompt: "test",
      resumeSnapshot: [],
      interruptFlag: interruptFlag,
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

  @Test func multipleTurnsAccumulateTranscript() async {
    let (lines, cont) = AsyncStream<String>.makeStream()
    let interruptFlag = ModelTurnInterruptFlag()
    let events: Mutex<[HostEvent]> = Mutex([])

    let coordinator = ChatCoordinator(
      configuration: .testValue,
      systemPrompt: "test",
      resumeSnapshot: [],
      interruptFlag: interruptFlag,
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

  // MARK: - Interrupt flag propagates to turn options

  @Test func interruptFlagIsClearedBeforeEachTurn() async {
    let (lines, cont) = AsyncStream<String>.makeStream()
    let interruptFlag = ModelTurnInterruptFlag()
    let events: Mutex<[HostEvent]> = Mutex([])

    // Pre-set the flag — it should be cleared before the turn.
    interruptFlag.request()
    #expect(interruptFlag.peek())

    let coordinator = ChatCoordinator(
      configuration: .testValue,
      systemPrompt: "test",
      resumeSnapshot: [],
      interruptFlag: interruptFlag,
      log: log,
      enqueue: { event in events.withLock { $0.append(event) } },
      persistURL: URL(fileURLWithPath: "/tmp/test-interrupt-clear-\(UUID().uuidString)"),
      sessionId: UUID(),
      sessionCreatedAt: Date(),
      lines: lines,
      makeAgent: { _ in MockAgent.makeDefault() }
    )

    let task = Task { await coordinator.run() }
    cont.yield("hello")
    cont.finish()
    _ = await task.value

    // After the turn, the flag should have been cleared by the coordinator.
    #expect(!interruptFlag.peek(), "Interrupt flag should be cleared after turn dispatch")
  }

  // MARK: - ModelTurnInterruptFlag (standalone)

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
        group.addTask { flag.request() }
        group.addTask { _ = flag.peek() }
        group.addTask { flag.clear() }
      }
    }
    _ = flag.peek()
  }

  // MARK: - Resume snapshot

  @Test func resumeSnapshotWithSystemMessage() async {
    let (lines, _) = AsyncStream<String>.makeStream()
    let interruptFlag = ModelTurnInterruptFlag()
    let events: Mutex<[HostEvent]> = Mutex([])

    let resume: [Components.Schemas.ChatMessage] = [
      .init(role: .system, content: "resumed system prompt"),
      .init(role: .user, content: "previous message"),
    ]

    let coordinator = ChatCoordinator(
      configuration: .testValue,
      systemPrompt: "default prompt",
      resumeSnapshot: resume,
      interruptFlag: interruptFlag,
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
