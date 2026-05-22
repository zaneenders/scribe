import Foundation
import ScribeCore
import Testing

@testable import ScribeCLI

// MARK: - renderMessagesToTranscript tests

/// Tests for `renderMessagesToTranscript()` — a pure function that walks persisted
/// messages and produces styled transcript lines.
@Suite
struct TranscriptReplayTests {

  // MARK: - Single-turn session with text only

  @Test func singleTurnTextOnly() {
    let messages: [ScribeMessage] = [
      ScribeMessage(role: .system, content: "You are a test agent."),
      ScribeMessage(role: .user, content: "hello"),
      ScribeMessage(role: .assistant, content: "Hi there!"),
    ]

    let lines = renderMessagesToTranscript(messages, theme: .default, renderer: SwiftMarkdownRenderer())

    // Should have: you:, "  hello", blank, scribe:, "  · answer", "Hi there!", blank
    #expect(lines.count >= 7)
    #expect(lines[0].spans.first?.text == "you:")
    #expect(lines[1].spans.first?.text == "  hello")
    #expect(lines[2].spans.isEmpty)  // blank
    #expect(lines[3].spans.first?.text == "scribe:")
    #expect(lines[4].spans.first?.text == "  · answer")
    #expect(lines[5].spans.first?.text == "Hi there!")
  }

  // MARK: - Multi-line user submission

  @Test func multiLineUserSubmission() {
    let messages: [ScribeMessage] = [
      ScribeMessage(role: .user, content: "line1\nline2\nline3"),
      ScribeMessage(role: .assistant, content: "ok"),
    ]

    let lines = renderMessagesToTranscript(messages, theme: .default, renderer: SwiftMarkdownRenderer())

    // you:, "  line1", "  line2", "  line3", blank, scribe:, "  · answer", "ok", blank
    #expect(lines[0].spans.first?.text == "you:")
    #expect(lines[1].spans.first?.text == "  line1")
    #expect(lines[2].spans.first?.text == "  line2")
    #expect(lines[3].spans.first?.text == "  line3")
  }

  // MARK: - Reasoning + answer

  @Test func reasoningAndAnswer() {
    let messages: [ScribeMessage] = [
      ScribeMessage(role: .user, content: "think"),
      ScribeMessage(
        role: .assistant, content: "answer text",
        reasoning: "reasoning text"),
    ]

    let lines = renderMessagesToTranscript(messages, theme: .default, renderer: SwiftMarkdownRenderer())

    // Should contain reasoning section followed by answer section
    let texts = lines.map { $0.spans.map(\.text).joined() }
    #expect(texts.contains("  · reasoning"))
    #expect(texts.contains("  · answer"))
  }

  // MARK: - Tool calls

  @Test func toolCallsWithOutput() {
    let messages: [ScribeMessage] = [
      ScribeMessage(role: .user, content: "run tool"),
      ScribeMessage(
        role: .assistant, content: "",
        toolCalls: [
          ScribeToolCall(id: "call_1", name: "shell", arguments: #"{"command":"ls"}"#)
        ]),
      ScribeMessage(role: .tool, content: "file1\nfile2", toolCallId: "call_1"),
    ]

    let lines = renderMessagesToTranscript(messages, theme: .default, renderer: SwiftMarkdownRenderer())

    let texts = lines.map { $0.spans.map(\.text).joined() }
    #expect(texts.contains(where: { $0.contains("tool round") }))
    #expect(texts.contains(where: { $0.contains("▶ shell") }))
  }

  // MARK: - Empty assistant turn

  @Test func emptyAssistantTurn() {
    let messages: [ScribeMessage] = [
      ScribeMessage(role: .user, content: "test"),
      ScribeMessage(role: .assistant, content: ""),
    ]

    let lines = renderMessagesToTranscript(messages, theme: .default, renderer: SwiftMarkdownRenderer())

    // Should still have scribe: and answer section headers
    let texts = lines.map { $0.spans.map(\.text).joined() }
    #expect(texts.contains("scribe:"))
    #expect(texts.contains("  · answer"))
  }

  // MARK: - Multiple turns

  @Test func multipleTurns() {
    let messages: [ScribeMessage] = [
      ScribeMessage(role: .user, content: "first"),
      ScribeMessage(role: .assistant, content: "response 1"),
      ScribeMessage(role: .user, content: "second"),
      ScribeMessage(role: .assistant, content: "response 2"),
    ]

    let lines = renderMessagesToTranscript(messages, theme: .default, renderer: SwiftMarkdownRenderer())

    let texts = lines.map { $0.spans.map(\.text).joined() }
    let youCount = texts.filter { $0 == "you:" }.count
    let scribeCount = texts.filter { $0 == "scribe:" }.count
    #expect(youCount == 2)
    #expect(scribeCount == 2)
  }

  // MARK: - Tool calls with multiple tools in one round

  @Test func multipleToolsInOneRound() {
    let messages: [ScribeMessage] = [
      ScribeMessage(role: .user, content: "use tools"),
      ScribeMessage(
        role: .assistant, content: "",
        toolCalls: [
          ScribeToolCall(id: "c1", name: "read_file", arguments: #"{"path":"a.swift"}"#),
          ScribeToolCall(id: "c2", name: "shell", arguments: #"{"command":"ls"}"#),
        ]),
      ScribeMessage(role: .tool, content: "content a", toolCallId: "c1"),
      ScribeMessage(role: .tool, content: "content b", toolCallId: "c2"),
    ]

    let lines = renderMessagesToTranscript(messages, theme: .default, renderer: SwiftMarkdownRenderer())

    let texts = lines.map { $0.spans.map(\.text).joined() }
    #expect(texts.contains(where: { $0.contains("▶ read_file") }))
    #expect(texts.contains(where: { $0.contains("▶ shell") }))
  }

  // MARK: - Skips system messages after the first

  @Test func skipsSystemMessages() {
    let messages: [ScribeMessage] = [
      ScribeMessage(role: .system, content: "system 1"),
      ScribeMessage(role: .system, content: "system 2"),
      ScribeMessage(role: .user, content: "hi"),
      ScribeMessage(role: .assistant, content: "hey"),
    ]

    let lines = renderMessagesToTranscript(messages, theme: .default, renderer: SwiftMarkdownRenderer())

    // Should only have one user/assistant pair, not system messages
    let texts = lines.map { $0.spans.map(\.text).joined() }
    #expect(!texts.contains(where: { $0.contains("system") }))
    #expect(texts.contains("you:"))
  }

  // MARK: - Empty user content is skipped

  @Test func emptyUserContentSkipped() {
    let messages: [ScribeMessage] = [
      ScribeMessage(role: .user, content: ""),
      ScribeMessage(role: .assistant, content: "response"),
    ]

    let lines = renderMessagesToTranscript(messages, theme: .default, renderer: SwiftMarkdownRenderer())

    // No "you:" line since user content was empty
    let texts = lines.map { $0.spans.map(\.text).joined() }
    #expect(!texts.contains("you:"))
  }

  // MARK: - renderMessagesToTranscriptWithStarts

  /// `messageStartLines` has length `count + 1`, starts at 0 for the first
  /// rendered message, ends at `lines.count`, and is non-decreasing.
  /// Messages that produce no own output (system, tool absorbed into an
  /// assistant round) share a start with the next produced line so the
  /// boundary picker can map any cut index to a real row.
  @Test func renderWithStartsProducesMonotonicMap() {
    let messages: [ScribeMessage] = [
      ScribeMessage(role: .system, content: "sys"),
      ScribeMessage(role: .user, content: "q1"),
      ScribeMessage(role: .assistant, content: "a1"),
      ScribeMessage(role: .user, content: "q2"),
      ScribeMessage(
        role: .assistant, content: "",
        toolCalls: [ScribeToolCall(id: "c1", name: "shell", arguments: "{}")]),
      ScribeMessage(role: .tool, content: "ok", name: "shell", toolCallId: "c1"),
      ScribeMessage(role: .assistant, content: "done"),
    ]
    let result = renderMessagesToTranscriptWithStarts(
      messages, theme: .default, renderer: SwiftMarkdownRenderer())

    #expect(result.messageStartLines.count == messages.count + 1)
    #expect(result.messageStartLines.last == result.lines.count)
    #expect(result.messageStartLines.first == 0)
    let starts = result.messageStartLines
    for i in 1..<starts.count {
      #expect(starts[i] >= starts[i - 1])
    }
    // The trailing assistant ("done") starts after the tool round, so its
    // line points at a real "scribe:" row, not the very end.
    let doneStart = starts[6]
    #expect(doneStart < result.lines.count)
    let lineText = result.lines[doneStart].spans.map(\.text).joined()
    #expect(lineText.isEmpty || lineText.contains("scribe") || lineText.contains("done"))
  }

  /// The existing `renderMessagesToTranscript` is now a thin wrapper —
  /// confirm it returns the same lines as the `WithStarts` form.
  @Test func renderWrapperMatchesWithStarts() {
    let messages: [ScribeMessage] = [
      ScribeMessage(role: .user, content: "hi"),
      ScribeMessage(role: .assistant, content: "yo"),
    ]
    let plain = renderMessagesToTranscript(
      messages, theme: .default, renderer: SwiftMarkdownRenderer())
    let withStarts = renderMessagesToTranscriptWithStarts(
      messages, theme: .default, renderer: SwiftMarkdownRenderer())
    #expect(plain == withStarts.lines)
  }
}
