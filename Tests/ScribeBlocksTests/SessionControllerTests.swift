import Foundation
import ScribeCore
import ScribeKit
import SystemPackage
import Testing

@testable import ScribeBlocks

@MainActor
@Suite
struct TranscriptReplayTests {

  @Test func replayMapsPersistedMessagesToTranscriptItems() {
    let messages: [ScribeMessage] = [
      ScribeMessage(role: .system, content: "sys"),
      ScribeMessage(role: .user, content: "hello"),
      ScribeMessage(
        role: .assistant,
        content: "answer",
        toolCalls: [ScribeToolCall(id: "c1", name: "read_file", arguments: #"{"path":"/tmp/a"}"#)],
        reasoning: "thinking"),
      ScribeMessage(
        role: .tool,
        content: #"{"ok":true,"content":"body","bytes":4,"totalLines":1}"#,
        name: "read_file",
        toolCallId: "c1"),
    ]

    let items = SessionController.replay(messages)

    #expect(items.map(\.kind.testName) == ["user", "reasoning", "answer", "tool"])
    #expect(items[0].title == "You")
    #expect(items[0].text == "hello")
    #expect(items[0].sourceMessageIndex == 1)
    #expect(items[1].title == "Reasoning")
    #expect(items[1].text == "thinking")
    #expect(items[1].sourceMessageIndex == 2)
    #expect(items[2].title == "Scribe")
    #expect(items[2].text == "answer")
    #expect(items[3].title == "read_file")
    #expect(items[3].text.contains("/tmp/a"))
    #expect(items[3].text.contains("4 bytes"))
    #expect(items[3].running == false)
  }

  @Test func replaySkipsSystemAndEmptyAssistantContent() {
    let messages: [ScribeMessage] = [
      ScribeMessage(role: .system, content: "sys"),
      ScribeMessage(role: .assistant, content: ""),
    ]

    #expect(SessionController.replay(messages).isEmpty)
  }

  @Test func replayWithNoRunningToolCallCreatesStandaloneToolItem() {
    let messages: [ScribeMessage] = [
      ScribeMessage(role: .system, content: "sys"),
      ScribeMessage(
        role: .tool,
        content: #"{"ok":true,"exitCode":0}"#,
        name: "shell",
        toolCallId: "c9"),
    ]

    let items = SessionController.replay(messages)

    #expect(items.count == 1)
    #expect(items[0].kind.testName == "tool")
    #expect(items[0].title == "shell")
    #expect(items[0].text.contains("exit 0"))
    #expect(items[0].running == false)
    #expect(items[0].sourceMessageIndex == 1)
  }

  @Test func controllerReplaysInitialMessagesDuringInit() throws {
    let messages: [ScribeMessage] = [
      ScribeMessage(role: .system, content: "sys"),
      ScribeMessage(role: .user, content: "hi"),
      ScribeMessage(role: .assistant, content: "hello"),
    ]
    let controller = try makeController(
      transport: TestTransport(responses: [.init(chunks: [])]),
      messages: messages)

    #expect(controller.transcript.map(\.kind.testName) == ["user", "answer"])
    #expect(controller.transcript.map(\.text) == ["hi", "hello"])
    #expect(controller.isLoadingTranscript == false)
  }
}

@MainActor
@Suite
struct EventReductionTests {

  private func makeEmptyController() throws -> SessionController {
    try makeController(transport: TestTransport(responses: [.init(chunks: [])]))
  }

  @Test func streamsReasoningThenAnswer() throws {
    let controller = try makeEmptyController()

    controller.reduce(.output(.sectionStarted(.reasoning, previous: nil)))
    controller.reduce(.output(.text(.reasoning, "thinking")))
    controller.reduce(.output(.sectionStarted(.answer, previous: .reasoning)))
    controller.reduce(.output(.text(.answer, "hello")))

    #expect(controller.transcript.map(\.kind.testName) == ["reasoning", "answer"])
    #expect(controller.transcript[0].title == "Reasoning")
    #expect(controller.transcript[0].text == "thinking")
    #expect(controller.transcript[0].running)
    #expect(controller.transcript[1].title == "Scribe")
    #expect(controller.transcript[1].text == "hello")
    #expect(controller.transcript[1].running)
  }

  @Test func repeatedSectionStartDoesNotDuplicateItem() throws {
    let controller = try makeEmptyController()

    controller.reduce(.output(.sectionStarted(.answer, previous: nil)))
    controller.reduce(.output(.text(.answer, "one")))
    controller.reduce(.output(.sectionStarted(.answer, previous: .answer)))
    controller.reduce(.output(.text(.answer, "two")))

    #expect(controller.transcript.count == 1)
    #expect(controller.transcript[0].text == "onetwo")
  }

  @Test func emptyOutputRecordsNotice() throws {
    let controller = try makeEmptyController()

    controller.reduce(.output(.empty))

    #expect(controller.transcript.map(\.kind.testName) == ["notice"])
    #expect(controller.transcript[0].title == "Scribe")
    #expect(controller.transcript[0].text == "Empty response.")
  }

  @Test func usageUpdatesUsageText() throws {
    let controller = try makeEmptyController()

    controller.reduce(.lifecycle(.usage(ScribeUsage(totalTokens: 42), tokensPerSecond: 10.5)))

    #expect(controller.transcript.isEmpty)
    #expect(controller.usageText == "42 tokens | 10.5 tok/s")
  }

  @Test func lifecycleErrorsRetriesAndRecoveriesBecomeTranscriptItems() throws {
    let controller = try makeEmptyController()

    controller.reduce(.lifecycle(.error(.generic("boom"))))
    controller.reduce(
      .lifecycle(.retrying(attempt: 2, maxRetries: 3, delay: .milliseconds(1500), reason: "rate limited")))
    controller.reduce(.lifecycle(.recovered(reason: "compacted context")))
    controller.reduce(.tool(.warning("careful")))

    #expect(controller.transcript.map(\.kind.testName) == ["error", "warning", "warning", "warning"])
    #expect(controller.transcript[0].title == "Error")
    #expect(controller.transcript[0].text == "boom")
    #expect(controller.transcript[1].title == "Retrying")
    #expect(controller.transcript[1].text == "rate limited (attempt 2/3, delay: 1.5s)")
    #expect(controller.transcript[2].title == "Recovered")
    #expect(controller.transcript[2].text == "compacted context")
    #expect(controller.transcript[3].title == "Warning")
    #expect(controller.transcript[3].text == "careful")
  }

  @Test func toolBoundariesUpsertSingleRunningItem() throws {
    let controller = try makeEmptyController()

    controller.reduce(.boundary(.toolExecutionStart(name: "shell", arguments: #"{"command":"ls"}"#)))
    #expect(controller.transcript.count == 1)
    #expect(controller.transcript[0].kind.testName == "tool")
    #expect(controller.transcript[0].title == "shell")
    #expect(controller.transcript[0].text == "ls")
    #expect(controller.transcript[0].running)

    controller.reduce(.boundary(.toolExecutionEnd(name: "shell", output: #"{"ok":true,"exitCode":0}"#)))
    #expect(controller.transcript.count == 1)
    #expect(controller.transcript[0].running == false)
    #expect(controller.transcript[0].text.contains("ls"))
    #expect(controller.transcript[0].text.contains("exit 0"))
  }

  @Test func finalizedInvocationLifecycleAndPlainBoundariesAreIgnored() throws {
    let controller = try makeEmptyController()

    controller.reduce(.output(.finalized))
    controller.reduce(.tool(.invocation(name: "x", arguments: "{}", output: "y")))
    controller.reduce(.lifecycle(.interrupted))
    controller.reduce(.boundary(.agentStart))
    controller.reduce(.boundary(.turnStart(round: 1)))

    #expect(controller.transcript.isEmpty)
  }
}

@MainActor
@Suite
struct SubmitAndQueueTests {

  @Test func submitStreamsUserPromptAndAnswer() async throws {
    let controller = try makeController(
      transport: TestTransport(responses: [.init(chunks: replyChunks("hi"))]))

    controller.updateDraft("hello")
    controller.submit()

    #expect(controller.isRunning)
    #expect(controller.draft.isEmpty)

    let finished = await waitUntil { !controller.isRunning }
    #expect(finished)
    #expect(controller.transcript.contains { $0.kind.testName == "user" && $0.text == "hello" })
    #expect(controller.transcript.contains { $0.kind.testName == "answer" && $0.text == "hi" })
  }

  @Test func submitIgnoresBlankDraft() throws {
    let controller = try makeController(
      transport: TestTransport(responses: [.init(chunks: replyChunks("hi"))]))

    controller.updateDraft("   \n ")
    controller.submit()

    #expect(!controller.isRunning)
    #expect(controller.transcript.isEmpty)
  }

  @Test func promptSubmittedWhileRunningIsQueuedThenDrained() async throws {
    let transport = TestTransport(
      responses: [.init(chunks: replyChunks("ok"))],
      gateFirstCall: true)
    let controller = try makeController(transport: transport)

    controller.submit("first")
    await transport.waitForFirstRequest()
    #expect(controller.isRunning)

    controller.submit("second")
    #expect(controller.queuedTexts == ["second"])

    transport.openGate()
    let finished = await waitUntil { !controller.isRunning }
    #expect(finished)
    #expect(controller.transcript.filter { $0.kind.testName == "user" }.map(\.text) == ["first", "second"])
    #expect(controller.queuedTexts.isEmpty)
  }

  @Test func clearQueueDropsPendingMessagesAndRecordsNotice() async throws {
    let transport = TestTransport(
      responses: [.init(chunks: replyChunks("ok"))],
      gateFirstCall: true)
    let controller = try makeController(transport: transport)

    controller.submit("first")
    await transport.waitForFirstRequest()
    controller.submit("second")
    #expect(controller.queuedTexts == ["second"])

    controller.clearQueue()
    #expect(controller.queuedTexts.isEmpty)
    #expect(controller.transcript.contains { $0.kind.testName == "notice" && $0.text == "Cleared 1 queued message." })

    transport.openGate()
    let finished = await waitUntil { !controller.isRunning }
    #expect(finished)
    #expect(!controller.transcript.contains { $0.kind.testName == "user" && $0.text == "second" })
  }

  @Test func stopPreservesQueuedMessagesAndRecordsInterruption() async throws {
    let transport = TestTransport(
      responses: [.init(chunks: replyChunks("ok"))],
      hangFirstCall: true)
    let controller = try makeController(transport: transport)

    controller.submit("first")
    await transport.waitForFirstRequest()
    controller.submit("kept")
    #expect(controller.queuedTexts == ["kept"])

    controller.stop()
    let finished = await waitUntil { !controller.isRunning }
    #expect(finished)
    #expect(controller.queuedTexts == ["kept"])
    #expect(
      controller.transcript.contains {
        $0.title == "Queue" && $0.text == "Turn interrupted. 1 queued message preserved."
      })
    #expect(controller.transcript.contains { $0.kind.testName == "notice" && $0.text == "Response interrupted." })
  }

  @Test func forceSendNextInterruptsThenSendsRecalledMessage() async throws {
    let transport = TestTransport(
      responses: [.init(chunks: replyChunks("ok"))],
      hangFirstCall: true)
    let controller = try makeController(transport: transport)

    controller.submit("first")
    await transport.waitForFirstRequest()
    controller.submit("queued")
    #expect(controller.queuedTexts == ["queued"])

    controller.forceSendNext()
    #expect(controller.queuedTexts.isEmpty)
    #expect(controller.transcript.contains { $0.text == "Force-sending next: queued" })

    let sent = await waitUntil {
      controller.transcript.contains { $0.kind.testName == "user" && $0.text == "queued" }
    }
    #expect(sent)
    let finished = await waitUntil { !controller.isRunning }
    #expect(finished)
  }
}

@MainActor
@Suite
struct ForkIdentityTests {

  @Test func forkCreatesNewIdentityClearsPinAndNotifies() async throws {
    let sessionId = UUID()
    let directory = FilePath(
      FileManager.default.temporaryDirectory
        .appendingPathComponent("scribe-fork-\(UUID().uuidString)").path)
    try await ChatSessionStore.saveMetadata(
      ChatSessionMetadata(
        id: sessionId,
        createdAt: .distantPast,
        model: "test-model",
        cwd: "/tmp",
        baseURL: nil,
        scribeVersion: nil,
        isPinned: true),
      to: directory)
    defer { try? FileManager.default.removeItem(atPath: directory.string) }

    let seed: [ScribeMessage] = [
      ScribeMessage(role: .system, content: "sys"),
      ScribeMessage(role: .user, content: "q"),
      ScribeMessage(role: .assistant, content: "a"),
    ]
    let controller = try makeController(
      transport: TestTransport(responses: [.init(chunks: [])]),
      messages: seed,
      sessionId: sessionId,
      sessionDirectory: directory)
    #expect(controller.isPinned)

    var identityChange: (previous: UUID, successor: UUID)?
    controller.onIdentityChange = { previous, successor in
      identityChange = (previous, successor)
    }

    controller.openCommandPicker(.fork)
    let pickerReady = await waitUntil { controller.commandPicker != nil }
    #expect(pickerReady)

    controller.confirmCommandPicker()
    let forked = await waitUntil { controller.sessionId != sessionId }
    #expect(forked)
    #expect(!controller.isPinned)
    #expect(controller.sessionId != sessionId)
    #expect(controller.sessionDirectory != directory)
    #expect(identityChange?.previous == sessionId)
    #expect(identityChange?.successor == controller.sessionId)
    #expect(controller.transcript.contains { $0.kind.testName == "notice" && $0.title == "Fork" })
    #expect(controller.commandPicker == nil)
  }
}
