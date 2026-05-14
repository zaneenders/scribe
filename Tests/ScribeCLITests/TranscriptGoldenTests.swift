import Foundation
import ScribeCore
import Testing

@testable import ScribeCLI

// MARK: - TranscriptGoldenTests

/// Golden tests that compare the streaming transcript render path against
/// the batch render path (`renderMessagesToTranscript`) to detect drift.
@Suite
struct TranscriptGoldenTests {

  private let theme = CLITheme.default
  private let renderer: MarkdownRenderer = SwiftMarkdownRenderer()

  // MARK: - Simple message golden

  @Test func simpleUserAssistantGolden() {
    let messages: [ScribeMessage] = [
      ScribeMessage(role: .user, content: "hello"),
      ScribeMessage(role: .assistant, content: "Hi there!"),
    ]

    // Batch path
    let batchLines = renderMessagesToTranscript(messages, theme: theme, renderer: renderer)

    // Streaming path
    var driver = ChatDriver(renderer: renderer, theme: theme)
    driver.handle(TranscriptEvent.userSubmitted("hello"))
    driver.handle(TranscriptEvent.enterAssistantSection(.answer, previous: nil))
    driver.handle(TranscriptEvent.appendAssistantText(.answer, text: "Hi there!"))
    driver.handle(TranscriptEvent.finalizeAssistantStream)

    let streamingText = driver.state.lines.flatMap { $0.spans.map(\.text) }.joined()
    let batchText = batchLines.flatMap { $0.spans.map(\.text) }.joined()

    #expect(streamingText.contains("you:"))
    #expect(streamingText.contains("hello"))
    #expect(streamingText.contains("Hi there!"))
    #expect(streamingText.contains("Hi there!") == batchText.contains("Hi there!"))
    #expect(streamingText.contains("hello") == batchText.contains("hello"))
  }

  // MARK: - Multi-turn golden

  @Test func multiTurnGolden() {
    let messages: [ScribeMessage] = [
      ScribeMessage(role: .user, content: "first"),
      ScribeMessage(role: .assistant, content: "response one"),
      ScribeMessage(role: .user, content: "second"),
      ScribeMessage(role: .assistant, content: "response two"),
    ]

    let batchLines = renderMessagesToTranscript(messages, theme: theme, renderer: renderer)
    let batchText = batchLines.flatMap { $0.spans.map(\.text) }.joined()

    #expect(batchText.contains("first"))
    #expect(batchText.contains("response one"))
    #expect(batchText.contains("second"))
    #expect(batchText.contains("response two"))
    let youCount = batchLines.filter { $0.spans.contains(where: { $0.text == "you:" }) }.count
    #expect(youCount == 2)
    let scribeCount = batchLines.filter { $0.spans.contains(where: { $0.text == "scribe:" }) }.count
    #expect(scribeCount == 2)
  }

  // MARK: - Tool call golden

  @Test func toolCallGolden() {
    let messages: [ScribeMessage] = [
      ScribeMessage(role: .user, content: "list files"),
      ScribeMessage(
        role: .assistant,
        content: "",
        toolCalls: [
          ScribeToolCall(id: "t1", name: "shell", arguments: #"{"command":"ls"}"#)
        ]
      ),
      ScribeMessage(role: .tool, content: #"{"ok":true,"stdout":"file.txt\n","exitCode":0}"#, toolCallId: "t1"),
      ScribeMessage(role: .assistant, content: "Done!"),
    ]

    let batchLines = renderMessagesToTranscript(messages, theme: theme, renderer: renderer)
    let batchText = batchLines.flatMap { $0.spans.map(\.text) }.joined()

    #expect(batchText.contains("tool round 1"))
    #expect(batchText.contains("shell"))
    #expect(batchText.contains("Done!"))
  }

  // MARK: - Reasoning golden

  @Test func reasoningGolden() {
    let messages: [ScribeMessage] = [
      ScribeMessage(role: .user, content: "complex"),
      ScribeMessage(role: .assistant, content: "Answer is 42", reasoning: "Let me think..."),
    ]

    let batchLines = renderMessagesToTranscript(messages, theme: theme, renderer: renderer)
    let batchText = batchLines.flatMap { $0.spans.map(\.text) }.joined()

    #expect(batchText.contains("reasoning"))
    #expect(batchText.contains("Let me think"))
    #expect(batchText.contains("answer"))
    #expect(batchText.contains("Answer is 42"))
  }
}
