import Foundation
import ScribeCore
import ScribeLLM
import Testing

@testable import ScribeCLI

// MARK: - renderMessagesToTranscript tests

/// Tests for `renderMessagesToTranscript()` — a pure function that walks persisted
/// messages and produces styled transcript lines.
@Suite
struct TranscriptReplayTests {

  // MARK: - Single-turn session with text only

  @Test func singleTurnTextOnly() {
    let messages: [Components.Schemas.ChatMessage] = [
      .init(role: .system, content: "You are a test agent."),
      .init(role: .user, content: "hello"),
      .init(role: .assistant, content: "Hi there!", toolCalls: nil, reasoningContent: nil),
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
    let messages: [Components.Schemas.ChatMessage] = [
      .init(role: .user, content: "line1\nline2\nline3"),
      .init(role: .assistant, content: "ok"),
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
    let messages: [Components.Schemas.ChatMessage] = [
      .init(role: .user, content: "think"),
      .init(
        role: .assistant, content: "answer text",
        toolCalls: nil, reasoningContent: "reasoning text"),
    ]

    let lines = renderMessagesToTranscript(messages, theme: .default, renderer: SwiftMarkdownRenderer())

    // Should contain reasoning section followed by answer section
    let texts = lines.map { $0.spans.map(\.text).joined() }
    #expect(texts.contains("  · reasoning"))
    #expect(texts.contains("  · answer"))
  }

  // MARK: - Tool calls

  @Test func toolCallsWithOutput() {
    let messages: [Components.Schemas.ChatMessage] = [
      .init(role: .user, content: "run tool"),
      .init(
        role: .assistant, content: "",
        toolCalls: [
          .init(
            id: "call_1", _type: "function",
            function: .init(name: "shell", arguments: "{\"command\":\"ls\"}"))
        ], reasoningContent: nil),
      .init(role: .tool, content: "file1\nfile2", name: nil, toolCalls: nil, toolCallId: "call_1"),
    ]

    let lines = renderMessagesToTranscript(messages, theme: .default, renderer: SwiftMarkdownRenderer())

    let texts = lines.map { $0.spans.map(\.text).joined() }
    #expect(texts.contains(where: { $0.contains("tool round") }))
    #expect(texts.contains(where: { $0.contains("▶ shell") }))
  }

  // MARK: - Empty assistant turn

  @Test func emptyAssistantTurn() {
    let messages: [Components.Schemas.ChatMessage] = [
      .init(role: .user, content: "test"),
      .init(role: .assistant, content: "", toolCalls: nil, reasoningContent: nil),
    ]

    let lines = renderMessagesToTranscript(messages, theme: .default, renderer: SwiftMarkdownRenderer())

    // Should still have scribe: and answer section headers
    let texts = lines.map { $0.spans.map(\.text).joined() }
    #expect(texts.contains("scribe:"))
    #expect(texts.contains("  · answer"))
  }

  // MARK: - Multiple turns

  @Test func multipleTurns() {
    let messages: [Components.Schemas.ChatMessage] = [
      .init(role: .user, content: "first"),
      .init(role: .assistant, content: "response 1"),
      .init(role: .user, content: "second"),
      .init(role: .assistant, content: "response 2"),
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
    let messages: [Components.Schemas.ChatMessage] = [
      .init(role: .user, content: "use tools"),
      .init(
        role: .assistant, content: "",
        toolCalls: [
          .init(
            id: "c1", _type: "function",
            function: .init(name: "read_file", arguments: "{\"path\":\"a.swift\"}")),
          .init(
            id: "c2", _type: "function",
            function: .init(name: "shell", arguments: "{\"command\":\"ls\"}")),
        ], reasoningContent: nil),
      .init(role: .tool, content: "content a", toolCallId: "c1"),
      .init(role: .tool, content: "content b", toolCallId: "c2"),
    ]

    let lines = renderMessagesToTranscript(messages, theme: .default, renderer: SwiftMarkdownRenderer())

    let texts = lines.map { $0.spans.map(\.text).joined() }
    #expect(texts.contains(where: { $0.contains("▶ read_file") }))
    #expect(texts.contains(where: { $0.contains("▶ shell") }))
  }

  // MARK: - Skips system messages after the first

  @Test func skipsSystemMessages() {
    let messages: [Components.Schemas.ChatMessage] = [
      .init(role: .system, content: "system 1"),
      .init(role: .system, content: "system 2"),
      .init(role: .user, content: "hi"),
      .init(role: .assistant, content: "hey"),
    ]

    let lines = renderMessagesToTranscript(messages, theme: .default, renderer: SwiftMarkdownRenderer())

    // Should only have one user/assistant pair, not system messages
    let texts = lines.map { $0.spans.map(\.text).joined() }
    #expect(!texts.contains(where: { $0.contains("system") }))
    #expect(texts.contains("you:"))
  }

  // MARK: - Empty user content is skipped

  @Test func emptyUserContentSkipped() {
    let messages: [Components.Schemas.ChatMessage] = [
      .init(role: .user, content: ""),
      .init(role: .assistant, content: "response"),
    ]

    let lines = renderMessagesToTranscript(messages, theme: .default, renderer: SwiftMarkdownRenderer())

    // No "you:" line since user content was empty
    let texts = lines.map { $0.spans.map(\.text).joined() }
    #expect(!texts.contains("you:"))
  }
}
