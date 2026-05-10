import Foundation
import Testing

@testable import ScribeCLI
@testable import ScribeCore
import ScribeLLM

// MARK: - TranscriptController tests

/// Tests for the `TranscriptController` state machine — pure functions of
/// `(state, event)` so they can be exercised without a running TUI.
@Suite
struct TranscriptControllerTests {

  private let theme: CLITheme = .default
  private let renderer: MarkdownRenderer = SwiftMarkdownRenderer()

  // MARK: - Initial state

  @Test func initialState() {
    let c = TranscriptController()
    #expect(c.completedLines.isEmpty)
    #expect(c.streamingOpenLine == nil)
    #expect(c.streamingRawText.isEmpty)
    #expect(c.streamingSectionStartLineIndex == nil)
    #expect(c.currentStreamingSection == .answer)
    #expect(c.generation == 0)
  }

  // MARK: - userSubmitted

  @Test func userSubmittedProducesCorrectLines() {
    var c = TranscriptController()
    let result = c.apply(.userSubmitted("hello"), theme: theme, renderer: renderer)
    #expect(result.needsRender)
    #expect(c.completedLines.count == 2)
    #expect(c.completedLines[0].spans[0].text == "you:")
    #expect(c.completedLines[1].spans[0].text == "  hello")
    #expect(c.streamingOpenLine == nil)
    #expect(c.generation > 0)
  }

  @Test func userSubmittedEmptyIsNoOp() {
    var c = TranscriptController()
    let result = c.apply(.userSubmitted(""), theme: theme, renderer: renderer)
    #expect(!result.needsRender)
    #expect(c.completedLines.isEmpty)
    #expect(c.generation == 0)
  }

  @Test func userSubmittedMultilineSplitsCorrectly() {
    var c = TranscriptController()
    _ = c.apply(.userSubmitted("line1\n\nline3"), theme: theme, renderer: renderer)
    // "you:", "  line1", "", "  line3" = 4 lines
    #expect(c.completedLines.count == 4)
    #expect(c.completedLines[0].spans[0].text == "you:")
    #expect(c.completedLines[1].spans[0].text == "  line1")
    #expect(c.completedLines[2].spans.isEmpty)  // blank line
    #expect(c.completedLines[3].spans[0].text == "  line3")
  }

  // MARK: - enterAssistantSection

  @Test func enterAssistantSectionAnswerAfterUser() {
    var c = TranscriptController()
    _ = c.apply(.userSubmitted("hello"), theme: theme, renderer: renderer)

    let result = c.apply(
      .enterAssistantSection(.answer, previous: nil), theme: theme, renderer: renderer)
    #expect(result.needsRender)
    // After userSubmitted("hello"), last completed line is "  hello" (not "you:"),
    // so isLastLineUserSubmission returns false and no blank separator is added.
    // Completed lines: ["you:", "  hello", "scribe:", "  · answer"]
    #expect(c.completedLines.count == 4)
    #expect(c.completedLines[c.completedLines.count - 2].spans[0].text == "scribe:")
    #expect(c.streamingOpenLine != nil)
    #expect(c.streamingRawText.isEmpty)
    #expect(c.streamingSectionStartLineIndex == c.completedLines.count)
    #expect(c.currentStreamingSection == .answer)
  }

  @Test func enterAssistantSectionReasoningAfterAnswer() {
    var c = TranscriptController()
    _ = c.apply(.userSubmitted("hello"), theme: theme, renderer: renderer)
    _ = c.apply(.enterAssistantSection(.answer, previous: nil), theme: theme, renderer: renderer)

    let result = c.apply(
      .enterAssistantSection(.reasoning, previous: .answer), theme: theme, renderer: renderer)
    #expect(result.needsRender)
    #expect(c.currentStreamingSection == .reasoning)
    #expect(c.streamingRawText.isEmpty)
  }

  @Test func enterAssistantSectionAnswerAfterReasoningAddsBlankLine() {
    var c = TranscriptController()
    _ = c.apply(.userSubmitted("hello"), theme: theme, renderer: renderer)
    _ = c.apply(.enterAssistantSection(.answer, previous: nil), theme: theme, renderer: renderer)
    _ = c.apply(
      .enterAssistantSection(.reasoning, previous: .answer), theme: theme, renderer: renderer)

    // Switching from reasoning back to answer should add a blank line
    let countBefore = c.completedLines.count
    let result = c.apply(
      .enterAssistantSection(.answer, previous: .reasoning), theme: theme, renderer: renderer)
    #expect(result.needsRender)
    // The blank line separator should have been added
    #expect(c.completedLines.count > countBefore)
    #expect(c.currentStreamingSection == .answer)
  }

  // MARK: - appendAssistantText

  @Test func appendAssistantTextAccumulatesRawText() {
    var c = TranscriptController()
    _ = c.apply(.userSubmitted("hello"), theme: theme, renderer: renderer)
    _ = c.apply(.enterAssistantSection(.answer, previous: nil), theme: theme, renderer: renderer)

    let result = c.apply(
      .appendAssistantText(.answer, text: "hello world"), theme: theme, renderer: renderer)
    #expect(result.needsRender)
    #expect(c.streamingRawText == "hello world")
    #expect(c.currentStreamingSection == .answer)
  }

  @Test func appendAssistantTextWithLiveRenderFalseStillAccumulatesButNoRender() {
    var c = TranscriptController()
    _ = c.apply(.userSubmitted("hello"), theme: theme, renderer: renderer)
    _ = c.apply(.enterAssistantSection(.answer, previous: nil), theme: theme, renderer: renderer)

    let result = c.apply(
      .appendAssistantText(.answer, text: "secret text"),
      theme: theme, renderer: renderer, liveRender: false)
    #expect(!result.needsRender)
    #expect(c.streamingRawText == "secret text")
  }

  @Test func appendAssistantTextMultipleChunksAccumulate() {
    var c = TranscriptController()
    _ = c.apply(.userSubmitted("hello"), theme: theme, renderer: renderer)
    _ = c.apply(.enterAssistantSection(.answer, previous: nil), theme: theme, renderer: renderer)

    _ = c.apply(.appendAssistantText(.answer, text: "hello "), theme: theme, renderer: renderer)
    _ = c.apply(.appendAssistantText(.answer, text: "world"), theme: theme, renderer: renderer)
    #expect(c.streamingRawText == "hello world")
  }

  @Test func appendAssistantTextUpdatesStreamingOpenLine() {
    var c = TranscriptController()
    _ = c.apply(.userSubmitted("hello"), theme: theme, renderer: renderer)
    _ = c.apply(.enterAssistantSection(.answer, previous: nil), theme: theme, renderer: renderer)

    _ = c.apply(
      .appendAssistantText(.answer, text: "simple text"), theme: theme, renderer: renderer)
    #expect(c.streamingOpenLine != nil)
    #expect(!c.streamingOpenLine!.spans.isEmpty)
  }

  // MARK: - finalizeAssistantStream

  @Test func finalizeAssistantStreamCommitsOpenLine() {
    var c = TranscriptController()
    _ = c.apply(.userSubmitted("hello"), theme: theme, renderer: renderer)
    _ = c.apply(.enterAssistantSection(.answer, previous: nil), theme: theme, renderer: renderer)
    _ = c.apply(.appendAssistantText(.answer, text: "final text"), theme: theme, renderer: renderer)

    let result = c.apply(.finalizeAssistantStream, theme: theme, renderer: renderer)
    #expect(result.needsRender)
    #expect(c.streamingOpenLine == nil)
    #expect(c.streamingRawText.isEmpty)
    #expect(c.streamingSectionStartLineIndex == nil)
  }

  // MARK: - emptyAssistantTurn

  @Test func emptyAssistantTurnProducesCorrectLines() {
    var c = TranscriptController()
    _ = c.apply(.userSubmitted("hello"), theme: theme, renderer: renderer)

    let result = c.apply(.emptyAssistantTurn, theme: theme, renderer: renderer)
    #expect(result.needsRender)
    // Should have appended "scribe:" and "(empty turn)"
    #expect(c.completedLines.count >= 3)
    let lastTwo = c.completedLines.suffix(2)
    #expect(lastTwo.first?.spans[0].text == "scribe:")
    #expect(lastTwo.last?.spans[0].text == "(empty turn)")
  }

  // MARK: - usage

  @Test func usageDoesNotMutateTranscript() {
    var c = TranscriptController()
    _ = c.apply(.userSubmitted("hello"), theme: theme, renderer: renderer)
    let countBefore = c.completedLines.count
    let genBefore = c.generation

    let result = c.apply(
      .usage(Components.Schemas.CompletionUsage(promptTokens: 10, completionTokens: 5, totalTokens: 15), tokensPerSecond: nil),
      theme: theme, renderer: renderer)
    #expect(!result.needsRender)
    #expect(c.completedLines.count == countBefore)
    #expect(c.generation == genBefore)
  }

  // MARK: - blankLine

  @Test func blankLineAppendsEmptyLine() {
    var c = TranscriptController()
    let result = c.apply(.blankLine, theme: theme, renderer: renderer)
    #expect(result.needsRender)
    #expect(c.completedLines.count == 1)
    #expect(c.completedLines[0].spans.isEmpty)
  }

  // MARK: - toolRoundHeader

  @Test func toolRoundHeaderProducesCorrectLine() {
    var c = TranscriptController()
    let result = c.apply(
      .toolRoundHeader(round: 3, toolNames: ["read", "write"]),
      theme: theme, renderer: renderer)
    #expect(result.needsRender)
    #expect(c.completedLines.count == 1)
    let text = c.completedLines[0].spans.map(\.text).joined()
    #expect(text.contains("tool round 3"))
    #expect(text.contains("read"))
    #expect(text.contains("write"))
  }

  // MARK: - toolInvocation

  @Test func toolInvocationProducesCorrectLines() {
    var c = TranscriptController()
    let result = c.apply(
      .toolInvocation(name: "read", arguments: "{}", output: "hello"),
      theme: theme, renderer: renderer)
    #expect(result.needsRender)
    #expect(c.completedLines.count >= 1)
    #expect(c.completedLines[0].spans[0].text.contains("▶ read"))
  }

  // MARK: - skippedUnreadableStreamLine

  @Test func skippedUnreadableStreamLineAppendsWarning() {
    var c = TranscriptController()
    let result = c.apply(.skippedUnreadableStreamLine, theme: theme, renderer: renderer)
    #expect(result.needsRender)
    #expect(c.completedLines.count == 1)
    #expect(c.completedLines[0].spans[0].text.contains("skipped"))
  }

  // MARK: - harnessError

  @Test func harnessErrorAppendsErrorLine() {
    var c = TranscriptController()
    let result = c.apply(
      .harnessError(.generic("test error")), theme: theme, renderer: renderer)
    #expect(result.needsRender)
    #expect(c.completedLines.count == 1)
    #expect(c.completedLines[0].spans[0].text.contains("error:"))
    #expect(c.completedLines[0].spans[0].text.contains("test error"))
  }

  // MARK: - turnInterrupted

  @Test func turnInterruptedClearsStreamingState() {
    var c = TranscriptController()
    _ = c.apply(.userSubmitted("hello"), theme: theme, renderer: renderer)
    _ = c.apply(.enterAssistantSection(.answer, previous: nil), theme: theme, renderer: renderer)
    _ = c.apply(.appendAssistantText(.answer, text: "partial"), theme: theme, renderer: renderer)

    let result = c.apply(.turnInterrupted, theme: theme, renderer: renderer)
    #expect(result.needsRender)
    #expect(c.streamingOpenLine == nil)
    #expect(c.streamingRawText.isEmpty)
    #expect(c.streamingSectionStartLineIndex == nil)
    #expect(c.completedLines.last?.spans[0].text == "(interrupted)")
  }

  // MARK: - turnComplete

  @Test func turnCompleteFinalizesWithExpectedDriftOnSeparators() {
    var c = TranscriptController()
    _ = c.apply(.userSubmitted("hello"), theme: theme, renderer: renderer)
    _ = c.apply(.enterAssistantSection(.answer, previous: nil), theme: theme, renderer: renderer)
    _ = c.apply(.appendAssistantText(.answer, text: "test"), theme: theme, renderer: renderer)
    _ = c.apply(.finalizeAssistantStream, theme: theme, renderer: renderer)

    // The batch render (renderMessagesToTranscript) adds blank-line separators
    // that the streaming path does not.  Drift on these separators is expected
    // and logged as a warning by the host.
    let refMessages: [Components.Schemas.ChatMessage] = [
      .init(role: .system, content: "sys"),
      .init(role: .user, content: "hello"),
      .init(role: .assistant, content: "test"),
    ]

    let result = c.apply(
      .turnComplete(referenceMessages: refMessages),
      theme: theme, renderer: renderer)
    #expect(result.needsRender)
    // Drift is expected — batch adds blank separators the streaming path omits.
    #expect(result.driftDetail != nil)
    #expect(result.driftDetail!.contains("streaming_count="))
  }

  @Test func turnCompleteDetectsDrift() {
    var c = TranscriptController()
    _ = c.apply(.userSubmitted("hello"), theme: theme, renderer: renderer)
    _ = c.apply(.enterAssistantSection(.answer, previous: nil), theme: theme, renderer: renderer)
    _ = c.apply(.appendAssistantText(.answer, text: "streamed"), theme: theme, renderer: renderer)
    _ = c.apply(.finalizeAssistantStream, theme: theme, renderer: renderer)

    // Reference messages have different content
    let refMessages: [Components.Schemas.ChatMessage] = [
      .init(role: .system, content: "sys"),
      .init(role: .user, content: "hello"),
      .init(role: .assistant, content: "different batch output"),
    ]

    let result = c.apply(
      .turnComplete(referenceMessages: refMessages),
      theme: theme, renderer: renderer)
    #expect(result.needsRender)
    #expect(result.driftDetail != nil)
  }

  // MARK: - isLastLineUserSubmission

  @Test func isLastLineUserSubmissionAfterUserSubmitted() {
    var c = TranscriptController()
    _ = c.apply(.userSubmitted("hello"), theme: theme, renderer: renderer)
    // Last completed line is "  hello" (the body), not "you:" (the prefix).
    #expect(!c.isLastLineUserSubmission())
  }

  @Test func isLastLineUserSubmissionWhenLastLineIsPrefix() {
    var c = TranscriptController()
    // Manually construct state where the last line is just the "you:" prefix.
    // This can happen in edge cases (e.g. userSubmitted with only newlines).
    c = TranscriptController(
      completedLines: [
        TLine(spans: [
          StyledSpan(
            fg: theme.userPrefix, bg: theme.background, bold: false, text: "you:")
        ])
      ],
      streamingOpenLine: nil,
      streamingRawText: "",
      streamingSectionStartLineIndex: nil,
      currentStreamingSection: .answer,
      generation: 1
    )
    #expect(c.isLastLineUserSubmission())
  }

  @Test func isLastLineUserSubmissionFalseWhenEmpty() {
    let c = TranscriptController()
    #expect(!c.isLastLineUserSubmission())
  }

  @Test func isLastLineUserSubmissionFalseAfterAssistant() {
    var c = TranscriptController()
    _ = c.apply(.userSubmitted("hello"), theme: theme, renderer: renderer)
    _ = c.apply(.enterAssistantSection(.answer, previous: nil), theme: theme, renderer: renderer)
    #expect(!c.isLastLineUserSubmission())
  }

  // MARK: - generation increments

  @Test func generationIncrementsOnMutation() {
    var c = TranscriptController()
    _ = c.apply(.userSubmitted("hello"), theme: theme, renderer: renderer)
    let gen = c.generation
    #expect(gen > 0)

    _ = c.apply(.blankLine, theme: theme, renderer: renderer)
    #expect(c.generation > gen)
  }

  // MARK: - Integrated turn scenario

  @Test func fullAssistantTurnStreamingProducesCorrectLines() {
    var c = TranscriptController()

    // User submits
    _ = c.apply(.userSubmitted("test"), theme: theme, renderer: renderer)
    // Last line is the body "  test", not the "you:" prefix.
    #expect(!c.isLastLineUserSubmission())

    // Enter answer section
    _ = c.apply(.enterAssistantSection(.answer, previous: nil), theme: theme, renderer: renderer)
    #expect(c.currentStreamingSection == .answer)
    #expect(c.streamingRawText.isEmpty)

    // Stream some text
    _ = c.apply(
      .appendAssistantText(.answer, text: "hello world"), theme: theme, renderer: renderer)
    #expect(c.streamingRawText == "hello world")
    #expect(c.streamingOpenLine != nil)

    // Finalize
    _ = c.apply(.finalizeAssistantStream, theme: theme, renderer: renderer)
    #expect(c.streamingOpenLine == nil)
    #expect(c.streamingRawText.isEmpty)
    #expect(c.streamingSectionStartLineIndex == nil)

    // Turn complete — drift on blank separators is expected (streaming vs batch).
    let refMessages: [Components.Schemas.ChatMessage] = [
      .init(role: .system, content: "sys"),
      .init(role: .user, content: "test"),
      .init(role: .assistant, content: "hello world"),
    ]
    let result = c.apply(
      .turnComplete(referenceMessages: refMessages),
      theme: theme, renderer: renderer)
    // Drift on blank-line separators is expected and normal.
    #expect(result.driftDetail != nil)
  }
}
