import Foundation
import ScribeCore
import Testing

@testable import ScribeKit

@Suite
struct ScribeTranscriptReplayTests {

  private let sessionID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

  private func fixtureMessages() -> [ScribeMessage] {
    [
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
  }

  @Test func replayMapsPersistedMessagesToItems() {
    let items = ScribeTranscriptState.replay(sessionID: sessionID, messages: fixtureMessages())

    #expect(items.map(\.kind) == [.user, .reasoning, .answer, .tool])
    #expect(items[0].title == "You")
    #expect(items[0].body == "hello")
    #expect(items[0].sourceMessageIndex == 1)
    #expect(items[1].title == "Reasoning")
    #expect(items[1].body == "thinking")
    #expect(items[1].sourceMessageIndex == 2)
    #expect(items[2].title == "Scribe")
    #expect(items[2].body == "answer")
    #expect(items[3].title == "read_file")
    #expect(items[3].body.contains("/tmp/a"))
    #expect(items[3].body.contains("4 bytes"))
    #expect(items[3].isRunning == false)
    #expect(items[3].sourceMessageIndex == 2)
  }

  @Test func replayIsDeterministicAcrossInvocations() {
    let first = ScribeTranscriptState.replay(sessionID: sessionID, messages: fixtureMessages())
    let second = ScribeTranscriptState.replay(sessionID: sessionID, messages: fixtureMessages())
    #expect(first == second)
    #expect(first.map(\.id) == second.map(\.id))
  }

  @Test func replayIDsAreScopedToSessionPositionAndSegment() {
    let items = ScribeTranscriptState.replay(sessionID: sessionID, messages: fixtureMessages())

    #expect(
      items[0].id
        == .replay(sessionID: sessionID, messageIndex: 1, segment: "user"))
    #expect(
      items[1].id
        == .replay(sessionID: sessionID, messageIndex: 2, segment: "reasoning"))
    #expect(
      items[2].id
        == .replay(sessionID: sessionID, messageIndex: 2, segment: "answer"))
    #expect(
      items[3].id
        == .replayToolCall(sessionID: sessionID, messageIndex: 2, callID: "c1"))
  }

  @Test func replayIDsDifferAcrossSessionsWithSameMessages() {
    let otherID = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
    let mine = ScribeTranscriptState.replay(sessionID: sessionID, messages: fixtureMessages())
    let theirs = ScribeTranscriptState.replay(sessionID: otherID, messages: fixtureMessages())

    #expect(mine.map(\.body) == theirs.map(\.body))
    #expect(Set(mine.map(\.id)).isDisjoint(with: Set(theirs.map(\.id))))
    #expect(mine[0].id != theirs[0].id)
  }

  @Test func toolResultAttachesToMatchingToolCallIdentity() {
    let messages: [ScribeMessage] = [
      ScribeMessage(role: .system, content: "sys"),
      ScribeMessage(role: .user, content: "run"),
      ScribeMessage(
        role: .assistant,
        content: "",
        toolCalls: [
          ScribeToolCall(id: "call-a", name: "shell", arguments: #"{"command":"ls"}"#),
          ScribeToolCall(id: "call-b", name: "read_file", arguments: #"{"path":"/tmp/b"}"#),
        ]),
      ScribeMessage(
        role: .tool,
        content: #"{"ok":true,"content":"body","bytes":4,"totalLines":1}"#,
        name: "read_file",
        toolCallId: "call-b"),
    ]
    let items = ScribeTranscriptState.replay(sessionID: sessionID, messages: messages)

    // The result attaches to its own call (call-b), not the still-running call-a.
    #expect(items.count == 3)
    #expect(items[1].id == .replayToolCall(sessionID: sessionID, messageIndex: 2, callID: "call-a"))
    #expect(items[1].isRunning)
    #expect(items[2].id == .replayToolCall(sessionID: sessionID, messageIndex: 2, callID: "call-b"))
    #expect(!items[2].isRunning)
    #expect(items[2].body.contains("4 bytes"))
  }

  @Test func standaloneToolResultWithoutRunningCallCreatesOwnItem() {
    let messages: [ScribeMessage] = [
      ScribeMessage(role: .system, content: "sys"),
      ScribeMessage(
        role: .tool,
        content: #"{"ok":true,"exitCode":0}"#,
        name: "shell",
        toolCallId: "c9"),
    ]
    let items = ScribeTranscriptState.replay(sessionID: sessionID, messages: messages)

    #expect(items.count == 1)
    #expect(items[0].kind == .tool)
    #expect(items[0].title == "shell")
    #expect(items[0].body.contains("exit 0"))
    #expect(!items[0].isRunning)
    #expect(items[0].sourceMessageIndex == 1)
    #expect(items[0].id == .replayToolResult(sessionID: sessionID, messageIndex: 1))
  }

  @Test func replaySkipsSystemAndEmptyAssistantContent() {
    let messages: [ScribeMessage] = [
      ScribeMessage(role: .system, content: "sys"),
      ScribeMessage(role: .assistant, content: ""),
    ]
    #expect(ScribeTranscriptState.replay(sessionID: sessionID, messages: messages).isEmpty)
  }

  @Test func initReplaysMessagesAndStateStartsClean() {
    let state = ScribeTranscriptState(sessionID: sessionID, messages: fixtureMessages())
    #expect(state.items.count == 4)
    #expect(state.usageText.isEmpty)
    #expect(state.sessionID == sessionID)
  }
}

@Suite
struct ScribeTranscriptReductionTests {

  private let sessionID = UUID(uuidString: "22222222-3333-4444-5555-666666666666")!

  @Test func streamsReasoningThenAnswerWithStableProvisionalIDs() {
    var state = ScribeTranscriptState(sessionID: sessionID)
    state.apply(.userPromptAccepted("hello"))
    state.apply(.sectionStarted(.reasoning))
    let reasoningID = state.items.last?.id
    state.apply(.sectionTextAppended(.reasoning, text: "thinking"))
    state.apply(.sectionTextAppended(.reasoning, text: "..."))
    state.apply(.sectionStarted(.answer))
    state.apply(.sectionTextAppended(.answer, text: "hi"))

    #expect(state.items.map(\.kind) == [.user, .reasoning, .answer])
    #expect(state.items[0].body == "hello")
    #expect(state.items[1].title == "Reasoning")
    #expect(state.items[1].body == "thinking...")
    #expect(state.items[1].isRunning)
    #expect(state.items[2].title == "Scribe")
    #expect(state.items[2].body == "hi")
    #expect(state.items[2].isRunning)
    // ID remains unchanged while streamed text is appended.
    #expect(state.items[1].id == reasoningID)
    #expect(
      state.items[1].id
        == .stream(sessionID: sessionID, turn: 1, segment: "reasoning"))
  }

  @Test func repeatedSectionStartDoesNotDuplicateItem() {
    var state = ScribeTranscriptState(sessionID: sessionID)
    state.apply(.userPromptAccepted("q"))
    state.apply(.sectionStarted(.answer))
    state.apply(.sectionTextAppended(.answer, text: "one"))
    state.apply(.sectionStarted(.answer))
    state.apply(.sectionTextAppended(.answer, text: "two"))

    #expect(state.items.filter { $0.kind == .answer }.count == 1)
    #expect(state.items.last?.body == "onetwo")
  }

  @Test func secondTurnGetsDistinctProvisionalIDs() {
    var state = ScribeTranscriptState(sessionID: sessionID)
    state.apply(.userPromptAccepted("one"))
    state.apply(.sectionStarted(.answer))
    state.apply(.sectionTextAppended(.answer, text: "first"))
    state.apply(
      .turnCompleted(
        .completed,
        messages: [
          ScribeMessage(role: .system, content: "sys"),
          ScribeMessage(role: .user, content: "one"),
          ScribeMessage(role: .assistant, content: "first"),
        ]))
    state.apply(.userPromptAccepted("two"))
    state.apply(.sectionStarted(.answer))
    state.apply(.sectionTextAppended(.answer, text: "second"))

    let answerIDs = state.items.filter { $0.kind == .answer }.map(\.id)
    #expect(answerIDs.count == 2)
    #expect(answerIDs[0] != answerIDs[1])
    // First turn's answer was reconciled to a deterministic replay ID.
    #expect(
      answerIDs[0] == .replay(sessionID: sessionID, messageIndex: 2, segment: "answer"))
    // Second turn's answer is still provisional with turn 2.
    #expect(answerIDs[1] == .stream(sessionID: sessionID, turn: 2, segment: "answer"))
  }

  @Test func terminalCompletionReconcilesProvisionalIDsToReplayIDs() {
    var state = ScribeTranscriptState(sessionID: sessionID)
    state.apply(.userPromptAccepted("hello"))
    state.apply(.sectionStarted(.answer))
    state.apply(.sectionTextAppended(.answer, text: "hi"))
    #expect(state.items.allSatisfy { $0.id.rawValue.hasPrefix("stream:") })

    let persisted: [ScribeMessage] = [
      ScribeMessage(role: .system, content: "sys"),
      ScribeMessage(role: .user, content: "hello"),
      ScribeMessage(role: .assistant, content: "hi"),
    ]
    state.apply(.turnCompleted(.completed, messages: persisted))

    #expect(state.items.map(\.kind) == [.user, .answer])
    #expect(
      state.items.map(\.id)
        == [
          .replay(sessionID: sessionID, messageIndex: 1, segment: "user"),
          .replay(sessionID: sessionID, messageIndex: 2, segment: "answer"),
        ])
    #expect(state.items.allSatisfy { $0.id.rawValue.hasPrefix("replay:") })
  }

  @Test func interruptedOutcomeRecordsNoticeAndReconcilesPersistedPrompt() {
    var state = ScribeTranscriptState(sessionID: sessionID)
    state.apply(.userPromptAccepted("hello"))
    state.apply(
      .turnCompleted(
        .interrupted,
        messages: [
          ScribeMessage(role: .system, content: "s"),
          ScribeMessage(role: .user, content: "hello"),
        ]))

    #expect(state.items.map(\.kind) == [.user, .notice])
    #expect(state.items[0].body == "hello")
    #expect(
      state.items[0].id == .replay(sessionID: sessionID, messageIndex: 1, segment: "user"))
    #expect(state.items[1].title == "Stopped")
    #expect(state.items[1].body == "Response interrupted.")
  }

  @Test func midTurnNoticesSurviveTerminalReconcile() {
    var state = ScribeTranscriptState(sessionID: sessionID)
    state.apply(.userPromptAccepted("hello"))
    state.apply(.warning("careful"))
    state.apply(.sectionStarted(.answer))
    state.apply(.sectionTextAppended(.answer, text: "hi"))
    state.apply(.turnCompleted(.completed, messages: [
      ScribeMessage(role: .system, content: "s"),
      ScribeMessage(role: .user, content: "hello"),
      ScribeMessage(role: .assistant, content: "hi"),
    ]))

    #expect(state.items.map(\.kind) == [.warning, .user, .answer])
    #expect(state.items[0].body == "careful")
    #expect(
      state.items[1].id == .replay(sessionID: sessionID, messageIndex: 1, segment: "user"))
    #expect(
      state.items[2].id == .replay(sessionID: sessionID, messageIndex: 2, segment: "answer"))
  }

  @Test func terminalFailureRecordsErrorItemWithoutReconcile() {
    var state = ScribeTranscriptState(sessionID: sessionID)
    state.apply(.userPromptAccepted("hello"))
    state.apply(.turnFailed("Connection lost."))

    #expect(state.items.map(\.kind) == [.user, .error])
    #expect(state.items[1].title == "Error")
    #expect(state.items[1].body == "Connection lost.")
    #expect(state.items[1].id.rawValue.hasPrefix("notice:"))
  }

  @Test func emptyOutputUsageWarningsErrorsRetriesAndRecoveryBecomeItems() {
    var state = ScribeTranscriptState(sessionID: sessionID)
    state.apply(.emptyOutput)
    state.apply(.usage(ScribeUsageSnapshot(totalTokens: 42, tokensPerSecond: 10.5)))
    state.apply(.warning("careful"))
    state.apply(.error("boom"))
    state.apply(.retrying(attempt: 2, maxAttempts: 3, delaySeconds: 1.5, reason: "rate limited"))
    state.apply(.recovered(reason: "compacted context"))

    #expect(
      state.items.map(\.kind) == [.notice, .warning, .error, .warning, .warning])
    #expect(state.items[0].title == "Scribe")
    #expect(state.items[0].body == "Empty response.")
    #expect(state.items[1].title == "Warning")
    #expect(state.items[1].body == "careful")
    #expect(state.items[2].title == "Error")
    #expect(state.items[2].body == "boom")
    #expect(state.items[3].title == "Retrying")
    #expect(state.items[3].body == "rate limited (attempt 2/3, delay: 1.5s)")
    #expect(state.items[4].title == "Recovered")
    #expect(state.items[4].body == "compacted context")
    #expect(state.usageText == "42 tokens | 10.5 tok/s")
  }

  @Test func toolBoundariesUpsertSingleItem() {
    var state = ScribeTranscriptState(sessionID: sessionID)
    state.apply(.userPromptAccepted("run"))
    state.apply(.toolInvocationStarted(name: "shell", arguments: #"{"command":"ls"}"#))
    #expect(state.items.last?.kind == .tool)
    #expect(state.items.last?.title == "shell")
    #expect(state.items.last?.body == "ls")
    #expect(state.items.last?.isRunning == true)

    state.apply(.toolInvocationCompleted(name: "shell", output: #"{"ok":true,"exitCode":0}"#))
    let toolItems = state.items.filter { $0.kind == .tool }
    #expect(toolItems.count == 1)
    #expect(toolItems[0].isRunning == false)
    #expect(toolItems[0].body.contains("ls"))
    #expect(toolItems[0].body.contains("exit 0"))
  }

  @Test func repeatedToolNameInOneTurnGetsDistinctIDs() {
    var state = ScribeTranscriptState(sessionID: sessionID)
    state.apply(.userPromptAccepted("run"))
    state.apply(.toolInvocationStarted(name: "shell", arguments: #"{"command":"ls"}"#))
    state.apply(.toolInvocationCompleted(name: "shell", output: #"{"ok":true,"exitCode":0}"#))
    state.apply(.toolInvocationStarted(name: "shell", arguments: #"{"command":"pwd"}"#))
    state.apply(.toolInvocationCompleted(name: "shell", output: #"{"ok":true,"exitCode":0}"#))

    let toolItems = state.items.filter { $0.kind == .tool }
    #expect(toolItems.count == 2)
    #expect(toolItems[0].id != toolItems[1].id)
    #expect(
      toolItems[0].id
        == .streamTool(sessionID: sessionID, turn: 1, name: "shell", occurrence: 1))
    #expect(
      toolItems[1].id
        == .streamTool(sessionID: sessionID, turn: 1, name: "shell", occurrence: 2))
  }

  @Test func toolRoundStartAndInterruptedAreIgnored() {
    var state = ScribeTranscriptState(sessionID: sessionID)
    state.apply(.toolRoundStarted(round: 1))
    state.apply(.interrupted)
    #expect(state.items.isEmpty)
  }

  @Test func identityChangeRescopesFutureReplayIDs() {
    var state = ScribeTranscriptState(sessionID: sessionID)
    let newID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    state.apply(.identityChanged(previousSessionID: sessionID, sessionID: newID))

    let persisted = [
      ScribeMessage(role: .system, content: "sys"),
      ScribeMessage(role: .user, content: "hi"),
    ]
    state.reconcile(messages: persisted)
    #expect(
      state.items[0].id == .replay(sessionID: newID, messageIndex: 1, segment: "user"))
  }

  @Test func discardActiveTurnRemovesOnlyCurrentTurnStreams() {
    var state = ScribeTranscriptState(sessionID: sessionID)
    state.apply(.userPromptAccepted("one"))
    state.apply(.turnCompleted(.completed, messages: [
      ScribeMessage(role: .system, content: "sys"),
      ScribeMessage(role: .user, content: "one"),
    ]))
    state.apply(.userPromptAccepted("two"))
    state.apply(.sectionStarted(.answer))
    state.apply(.sectionTextAppended(.answer, text: "partial"))

    state.discardActiveTurn()

    // Turn 1 items (reconciled replay items) survive; turn 2 streams are gone.
    #expect(state.items.map(\.kind) == [.user])
    #expect(state.items[0].body == "one")
  }

  @Test func appendPresentationItemAddsNoticeWarningError() {
    var state = ScribeTranscriptState(sessionID: sessionID)
    state.appendPresentationItem(kind: .notice, title: "Queue", body: "Cleared 1 queued message.")
    state.appendPresentationItem(kind: .error, title: "Fork", body: "Could not fork.")

    #expect(state.items.map(\.kind) == [.notice, .error])
    #expect(state.items[0].id != state.items[1].id)
    #expect(state.items.allSatisfy { $0.id.rawValue.hasPrefix("notice:") })
  }
}
