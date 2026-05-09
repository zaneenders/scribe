import Foundation
import ScribeCore
import ScribeLLM
import Synchronization
import Testing

// MARK: - TranscriptReplay tests

/// Tests for `TranscriptReplay.replay()` — a pure function that walks persisted
/// messages and emits `TranscriptEvent` values via closures.
@Suite
struct TranscriptReplayTests {

  // MARK: - Single-turn session with text only

  @Test func singleTurnTextOnly() {
    let messages: [Components.Schemas.ChatMessage] = [
      .init(role: .system, content: "You are a test agent."),
      .init(role: .user, content: "hello"),
      .init(role: .assistant, content: "Hi there!", toolCalls: nil, reasoningContent: nil),
    ]

    let events = Mutex<[TranscriptEvent]>([])
    let userSubmissions = Mutex<[String]>([])

    TranscriptReplay.replay(
      messages: messages,
      onEvent: { ev in events.withLock { $0.append(ev) } },
      recordUserSubmission: { s in userSubmissions.withLock { $0.append(s) } }
    )

    let capturedEvents = events.withLock { $0 }
    let capturedSubs = userSubmissions.withLock { $0 }

    // User submission recorded
    #expect(capturedSubs == ["hello"])

    // Events: enter answer section, append text, finalize, blankLine
    #expect(capturedEvents.count == 4)

    // First event: enter answer section (no reasoning → enters answer directly)
    guard case .enterAssistantSection(let section, let previous) = capturedEvents[0] else {
      #expect(Bool(false), "Expected enterAssistantSection")
      return
    }
    #expect(section == .answer)
    #expect(previous == nil)

    // Second event: append assistant text
    guard case .appendAssistantText(let section, let text) = capturedEvents[1] else {
      #expect(Bool(false), "Expected appendAssistantText")
      return
    }
    #expect(section == .answer)
    #expect(text == "Hi there!")

    // Third event: finalize
    guard case .finalizeAssistantStream = capturedEvents[2] else {
      #expect(Bool(false), "Expected finalizeAssistantStream")
      return
    }

    // Fourth event: blankLine after turn
    guard case .blankLine = capturedEvents[3] else {
      #expect(Bool(false), "Expected blankLine")
      return
    }
  }

  // MARK: - Empty user message is skipped

  @Test func emptyUserMessageIsSkipped() {
    let messages: [Components.Schemas.ChatMessage] = [
      .init(role: .system, content: "sys"),
      .init(role: .user, content: ""),
      .init(role: .assistant, content: "reply"),
    ]

    let userSubmissions = Mutex<[String]>([])
    let events = Mutex<[TranscriptEvent]>([])

    TranscriptReplay.replay(
      messages: messages,
      onEvent: { ev in events.withLock { $0.append(ev) } },
      recordUserSubmission: { s in userSubmissions.withLock { $0.append(s) } }
    )

    // Empty user content → no submission recorded
    #expect(userSubmissions.withLock { $0 }.isEmpty)

    // Assistant reply is still emitted
    let captured = events.withLock { $0 }
    let hasAnswer = captured.contains { event in
      if case .appendAssistantText(_, let text) = event, text == "reply" { return true }
      return false
    }
    #expect(hasAnswer)
  }

  // MARK: - Whitespace-only user message is skipped

  @Test func whitespaceOnlyUserMessageIsSkipped() {
    let messages: [Components.Schemas.ChatMessage] = [
      .init(role: .system, content: "sys"),
      .init(role: .user, content: "   "),
      .init(role: .assistant, content: "ok"),
    ]

    let userSubmissions = Mutex<[String]>([])

    TranscriptReplay.replay(
      messages: messages,
      onEvent: { _ in },
      recordUserSubmission: { s in userSubmissions.withLock { $0.append(s) } }
    )

    #expect(userSubmissions.withLock { $0 }.isEmpty)
  }

  // MARK: - Reasoning content

  @Test func reasoningContentBeforeAnswer() {
    let messages: [Components.Schemas.ChatMessage] = [
      .init(role: .system, content: "sys"),
      .init(role: .user, content: "think about it"),
      .init(
        role: .assistant, content: "answer text",
        toolCalls: nil, reasoningContent: "Let me think..."),
    ]

    let events = Mutex<[TranscriptEvent]>([])

    TranscriptReplay.replay(
      messages: messages,
      onEvent: { ev in events.withLock { $0.append(ev) } },
      recordUserSubmission: { _ in }
    )

    let captured = events.withLock { $0 }
    // Events: enter reasoning, append reasoning, enter answer, append answer, finalize, blankLine
    #expect(captured.count == 6)

    guard case .enterAssistantSection(.reasoning, nil) = captured[0] else {
      #expect(Bool(false), "Expected enter reasoning section")
      return
    }
    guard case .appendAssistantText(.reasoning, let rText) = captured[1] else {
      #expect(Bool(false), "Expected append reasoning text")
      return
    }
    #expect(rText == "Let me think...")

    guard case .enterAssistantSection(.answer, .some(.reasoning)) = captured[2] else {
      #expect(Bool(false), "Expected enter answer section after reasoning")
      return
    }
    guard case .appendAssistantText(.answer, let aText) = captured[3] else {
      #expect(Bool(false), "Expected append answer text")
      return
    }
    #expect(aText == "answer text")
  }

  // MARK: - Reasoning only (no content, no tool calls)

  @Test func reasoningOnlyWithoutAnswerText() {
    let messages: [Components.Schemas.ChatMessage] = [
      .init(role: .system, content: "sys"),
      .init(role: .user, content: "reflect"),
      .init(
        role: .assistant, content: "",
        toolCalls: nil, reasoningContent: "Hmm..."),
    ]

    let events = Mutex<[TranscriptEvent]>([])

    TranscriptReplay.replay(
      messages: messages,
      onEvent: { ev in events.withLock { $0.append(ev) } },
      recordUserSubmission: { _ in }
    )

    let captured = events.withLock { $0 }
    // When reasoning is present but content is empty and no tool calls,
    // only the reasoning section is emitted (no empty answer section).
    // Events: enter reasoning, append reasoning, finalize, blankLine
    #expect(captured.count == 4)

    guard case .enterAssistantSection(.reasoning, nil) = captured[0] else {
      #expect(Bool(false))
      return
    }
    guard case .appendAssistantText(.reasoning, let r) = captured[1] else {
      #expect(Bool(false))
      return
    }
    #expect(r == "Hmm...")
  }

  // MARK: - Tool calls

  @Test func toolCallsWithToolResponses() {
    let messages: [Components.Schemas.ChatMessage] = [
      .init(role: .system, content: "sys"),
      .init(role: .user, content: "run it"),
      .init(
        role: .assistant, content: "",
        toolCalls: [
          .init(
            id: "call_1", _type: "function",
            function: .init(name: "shell", arguments: #"{"command":"ls"}"#))
        ], reasoningContent: nil),
      .init(role: .tool, content: #"{"ok":true,"exit_code":0}"#, toolCallId: "call_1"),
      .init(role: .assistant, content: "done", toolCalls: nil, reasoningContent: nil),
    ]

    let events = Mutex<[TranscriptEvent]>([])

    TranscriptReplay.replay(
      messages: messages,
      onEvent: { ev in events.withLock { $0.append(ev) } },
      recordUserSubmission: { _ in }
    )

    let captured = events.withLock { $0 }

    // Find the tool round header
    let hasHeader = captured.contains { event in
      if case .toolRoundHeader(let round, let names) = event {
        return round == 1 && names == ["shell"]
      }
      return false
    }
    #expect(hasHeader)

    // Find the tool invocation with the output
    let hasInvocation = captured.contains { event in
      if case .toolInvocation(let name, let args, let output) = event {
        return name == "shell"
          && args == #"{"command":"ls"}"#
          && output.contains(#""ok":true"#)
      }
      return false
    }
    #expect(hasInvocation)
  }

  // MARK: - Multiple tool calls in one assistant message

  @Test func multipleToolCallsInSameRound() {
    let messages: [Components.Schemas.ChatMessage] = [
      .init(role: .system, content: "sys"),
      .init(role: .user, content: "do things"),
      .init(
        role: .assistant, content: "",
        toolCalls: [
          .init(
            id: "c1", _type: "function",
            function: .init(name: "read_file", arguments: #"{"path":"a.txt"}"#)),
          .init(
            id: "c2", _type: "function",
            function: .init(name: "shell", arguments: #"{"command":"ls"}"#)),
        ], reasoningContent: nil),
      .init(role: .tool, content: "content a", toolCallId: "c1"),
      .init(role: .tool, content: "output ls", toolCallId: "c2"),
    ]

    let events = Mutex<[TranscriptEvent]>([])

    TranscriptReplay.replay(
      messages: messages,
      onEvent: { ev in events.withLock { $0.append(ev) } },
      recordUserSubmission: { _ in }
    )

    let captured = events.withLock { $0 }

    // Tool round header lists both tools
    let header = captured.first { event in
      if case .toolRoundHeader(_, let names) = event {
        return names == ["read_file", "shell"]
      }
      return false
    }
    #expect(header != nil)

    // Two tool invocations
    let invocations = captured.filter { event in
      if case .toolInvocation = event { return true }
      return false
    }
    #expect(invocations.count == 2)

    // Two blankLines (one after each invocation)
    let blanks = captured.filter { event in
      if case .blankLine = event { return true }
      return false
    }
    #expect(blanks.count >= 2)
  }

  // MARK: - Multiple user turns

  @Test func multipleUserTurns() {
    let messages: [Components.Schemas.ChatMessage] = [
      .init(role: .system, content: "sys"),
      .init(role: .user, content: "first"),
      .init(role: .assistant, content: "reply1"),
      .init(role: .user, content: "second"),
      .init(role: .assistant, content: "reply2"),
    ]

    let userSubmissions = Mutex<[String]>([])

    TranscriptReplay.replay(
      messages: messages,
      onEvent: { _ in },
      recordUserSubmission: { s in userSubmissions.withLock { $0.append(s) } }
    )

    #expect(userSubmissions.withLock { $0 } == ["first", "second"])
  }

  // MARK: - Skipping leading system messages

  @Test func skipsLeadingSystemMessagesBeforeFirstUser() {
    let messages: [Components.Schemas.ChatMessage] = [
      .init(role: .system, content: "sys1"),
      .init(role: .system, content: "sys2"),  // multiple system messages
      .init(role: .user, content: "hello"),
      .init(role: .assistant, content: "hi"),
    ]

    let userSubmissions = Mutex<[String]>([])

    TranscriptReplay.replay(
      messages: messages,
      onEvent: { _ in },
      recordUserSubmission: { s in userSubmissions.withLock { $0.append(s) } }
    )

    #expect(userSubmissions.withLock { $0 } == ["hello"])
  }

  // MARK: - Tool call without matching tool response messages

  @Test func toolCallWithoutToolResponse() {
    let messages: [Components.Schemas.ChatMessage] = [
      .init(role: .system, content: "sys"),
      .init(role: .user, content: "do it"),
      .init(
        role: .assistant, content: "",
        toolCalls: [
          .init(
            id: "orphan", _type: "function",
            function: .init(name: "shell", arguments: "{}"))
        ], reasoningContent: nil),
    ]

    let events = Mutex<[TranscriptEvent]>([])

    TranscriptReplay.replay(
      messages: messages,
      onEvent: { ev in events.withLock { $0.append(ev) } },
      recordUserSubmission: { _ in }
    )

    let captured = events.withLock { $0 }
    // Tool invocation emitted with empty output (no tool messages follow)
    let invocation = captured.first { event in
      if case .toolInvocation(let name, _, let output) = event {
        return name == "shell" && output == ""
      }
      return false
    }
    #expect(invocation != nil)
  }

  // MARK: - Tool call with nil id and function

  @Test func toolCallWithNilFieldsUsesDefaults() {
    let messages: [Components.Schemas.ChatMessage] = [
      .init(role: .system, content: "sys"),
      .init(role: .user, content: "x"),
      .init(
        role: .assistant, content: "",
        toolCalls: [
          .init(id: nil, _type: nil, function: nil)
        ], reasoningContent: nil),
    ]

    let events = Mutex<[TranscriptEvent]>([])

    TranscriptReplay.replay(
      messages: messages,
      onEvent: { ev in events.withLock { $0.append(ev) } },
      recordUserSubmission: { _ in }
    )

    let captured = events.withLock { $0 }
    let invocation = captured.first { event in
      if case .toolInvocation = event { return true }
      return false
    }
    #expect(invocation != nil)
    if case .toolInvocation(let name, let args, _) = invocation! {
      #expect(name == "tool")  // fallback name
      #expect(args == "{}")    // fallback args
    }
  }

  // MARK: - Interleaved system messages mid-transcript are skipped

  @Test func systemMessagesMidTranscriptAreSkipped() {
    let messages: [Components.Schemas.ChatMessage] = [
      .init(role: .system, content: "sys"),
      .init(role: .user, content: "q1"),
      .init(role: .assistant, content: "a1"),
      .init(role: .system, content: "mid-sys"),  // should be skipped
      .init(role: .user, content: "q2"),
      .init(role: .assistant, content: "a2"),
    ]

    let userSubmissions = Mutex<[String]>([])

    TranscriptReplay.replay(
      messages: messages,
      onEvent: { _ in },
      recordUserSubmission: { s in userSubmissions.withLock { $0.append(s) } }
    )

    #expect(userSubmissions.withLock { $0 } == ["q1", "q2"])
  }

  // MARK: - Empty message list

  @Test func emptyMessagesProducesNoEvents() {
    let events = Mutex<[TranscriptEvent]>([])
    let submissions = Mutex<[String]>([])

    TranscriptReplay.replay(
      messages: [],
      onEvent: { ev in events.withLock { $0.append(ev) } },
      recordUserSubmission: { s in submissions.withLock { $0.append(s) } }
    )

    #expect(events.withLock { $0 }.isEmpty)
    #expect(submissions.withLock { $0 }.isEmpty)
  }

  // MARK: - System-only messages

  @Test func systemOnlyProducesNoEvents() {
    let messages: [Components.Schemas.ChatMessage] = [
      .init(role: .system, content: "sys"),
    ]

    let events = Mutex<[TranscriptEvent]>([])
    let submissions = Mutex<[String]>([])

    TranscriptReplay.replay(
      messages: messages,
      onEvent: { ev in events.withLock { $0.append(ev) } },
      recordUserSubmission: { s in submissions.withLock { $0.append(s) } }
    )

    #expect(events.withLock { $0 }.isEmpty)
    #expect(submissions.withLock { $0 }.isEmpty)
  }
}
