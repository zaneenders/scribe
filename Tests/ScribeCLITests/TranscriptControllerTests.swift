import Foundation
import ScribeCore
import ScribeLLM
import Testing

@testable import ScribeCLI

// MARK: - TranscriptController tests

/// Tests for the `TranscriptController` pure state machine — every event arm
/// is exercised without a running TUI, Slate, or async machinery.
@Suite
struct TranscriptControllerTests {

  private let theme = CLITheme.default
  private let renderer: MarkdownRenderer = SwiftMarkdownRenderer()

  // MARK: - .userSubmitted

  @Test func userSubmittedProducesYouPrefix() {
    var state = TranscriptState()
    let effects = TranscriptController.apply(
      .userSubmitted("hello"), to: &state, theme: theme, renderer: renderer,
      followingLive: true, contextWindow: nil)
    #expect(effects.needsRender)
    #expect(state.lines.count == 2)
    #expect(state.lines[0].spans[0].text == "you:")
    #expect(state.lines[1].spans[0].text.contains("hello"))
  }

  @Test func userSubmittedEmptyNoOp() {
    var state = TranscriptState()
    let effects = TranscriptController.apply(
      .userSubmitted(""), to: &state, theme: theme, renderer: renderer,
      followingLive: true, contextWindow: nil)
    #expect(!effects.needsRender)
    #expect(state.lines.isEmpty)
  }

  @Test func userSubmittedMultiLine() {
    var state = TranscriptState()
    let effects = TranscriptController.apply(
      .userSubmitted("hello\nworld"), to: &state, theme: theme, renderer: renderer,
      followingLive: true, contextWindow: nil)
    #expect(effects.needsRender)
    #expect(state.lines.count == 3)  // "you:" + "  hello" + "  world"
    #expect(state.lines[0].spans[0].text == "you:")
    #expect(state.lines[1].spans[0].text.contains("hello"))
    #expect(state.lines[2].spans[0].text.contains("world"))
  }

  // MARK: - .blankLine

  @Test func blankLine() {
    var state = TranscriptState()
    let effects = TranscriptController.apply(
      .blankLine, to: &state, theme: theme, renderer: renderer,
      followingLive: true, contextWindow: nil)
    #expect(effects.needsRender)
    #expect(state.lines.count == 1)
    #expect(state.lines[0].spans.isEmpty)
  }

  // MARK: - .toolRoundHeader

  @Test func toolRoundHeader() {
    var state = TranscriptState()
    let effects = TranscriptController.apply(
      .toolRoundHeader(round: 1, toolNames: ["shell", "read_file"]),
      to: &state, theme: theme, renderer: renderer,
      followingLive: true, contextWindow: nil)
    #expect(effects.needsRender)
    #expect(state.lines.count == 1)
    let text = state.lines[0].spans.map(\.text).joined()
    #expect(text.contains("tool round 1"))
    #expect(text.contains("shell"))
    #expect(text.contains("read_file"))
  }

  // MARK: - .toolInvocation

  @Test func toolInvocation() {
    var state = TranscriptState()
    let effects = TranscriptController.apply(
      .toolInvocation(name: "shell", arguments: #"{"command":"ls"}"#, output: #"{"ok":true,"stdout":"file.txt\n","exitCode":0}"#),
      to: &state, theme: theme, renderer: renderer,
      followingLive: true, contextWindow: nil)
    #expect(effects.needsRender)
    #expect(state.lines.count >= 1)
    let firstLine = state.lines[0].spans.map(\.text).joined()
    #expect(firstLine.contains("shell"))
  }

  // MARK: - .harnessError

  @Test func harnessError() {
    var state = TranscriptState()
    let effects = TranscriptController.apply(
      .harnessError(.generic("test error")),
      to: &state, theme: theme, renderer: renderer,
      followingLive: true, contextWindow: nil)
    #expect(effects.needsRender)
    #expect(state.lines.count == 1)
    #expect(state.lines[0].spans.map(\.text).joined().contains("test error"))
  }

  // MARK: - .turnInterrupted

  @Test func turnInterrupted() {
    var state = TranscriptState()
    state.streamingOpenLine = TLine(spans: [StyledSpan(fg: .white, bg: .black, bold: false, text: "partial")])
    state.streamingOpenLineRaw = "partial"
    state.streamingSectionStartLineIndex = 3

    let effects = TranscriptController.apply(
      .turnInterrupted, to: &state, theme: theme, renderer: renderer,
      followingLive: true, contextWindow: nil)
    #expect(effects.needsRender)
    #expect(state.streamingOpenLine == nil)
    #expect(state.streamingOpenLineRaw.isEmpty)
    #expect(state.streamingSectionStartLineIndex == nil)
    #expect(state.lines.last?.spans.map(\.text).joined() == "(interrupted)")
  }

  // MARK: - .emptyAssistantTurn

  @Test func emptyAssistantTurn() {
    var state = TranscriptState()
    let effects = TranscriptController.apply(
      .emptyAssistantTurn, to: &state, theme: theme, renderer: renderer,
      followingLive: true, contextWindow: nil)
    #expect(effects.needsRender)
    #expect(state.lines.count == 2)
    #expect(state.lines[0].spans[0].text == "scribe:")
    #expect(state.lines[1].spans[0].text == "(empty turn)")
  }

  // MARK: - .enterAssistantSection

  @Test func enterAssistantSectionAnswer() {
    var state = TranscriptState()
    _ = TranscriptController.apply(
      .userSubmitted("test"), to: &state, theme: theme, renderer: renderer,
      followingLive: true, contextWindow: nil)

    let effects = TranscriptController.apply(
      .enterAssistantSection(.answer, previous: nil),
      to: &state, theme: theme, renderer: renderer,
      followingLive: true, contextWindow: nil)
    #expect(effects.needsRender)
    // Should have: "you:", "  test", blank, "scribe:", "  · answer"
    #expect(state.lines.count >= 5)
    let scribeLine = state.lines[state.lines.count - 2].spans[0].text
    #expect(scribeLine == "scribe:")
    let labelLine = state.lines[state.lines.count - 1].spans[0].text
    #expect(labelLine == "  · answer")
  }

  @Test func enterAssistantSectionReasoning() {
    var state = TranscriptState()
    _ = TranscriptController.apply(
      .userSubmitted("test"), to: &state, theme: theme, renderer: renderer,
      followingLive: true, contextWindow: nil)

    let effects = TranscriptController.apply(
      .enterAssistantSection(.reasoning, previous: nil),
      to: &state, theme: theme, renderer: renderer,
      followingLive: true, contextWindow: nil)
    #expect(effects.needsRender)
    let labelLine = state.lines.last?.spans[0].text
    #expect(labelLine == "  · reasoning")
  }

  // MARK: - .usage

  @Test func usageUpdatesHUD() {
    var state = TranscriptState()
    let usage = Components.Schemas.CompletionUsage(
      promptTokens: 100,
      completionTokens: 50,
      totalTokens: 150,
      promptTokensDetails: nil,
      completionTokensDetails: nil
    )
    let effects = TranscriptController.apply(
      .usage(usage, tokensPerSecond: 10.5),
      to: &state, theme: theme, renderer: renderer,
      followingLive: true, contextWindow: 4000)
    #expect(effects.needsRender)
    #expect(state.usageTurnPrompt == 100)
    #expect(state.usageTurnCompletion == 50)
    #expect(state.usageTurnTotal == 150)
    #expect(state.usageHUD?.roundPrompt == 100)
    #expect(state.usageHUD?.outputTokensPerSecond == 10.5)
  }

  @Test func usageAccumulatesTurnTotals() {
    var state = TranscriptState()
    let u1 = Components.Schemas.CompletionUsage(
      promptTokens: 10, completionTokens: 5, totalTokens: 15,
      promptTokensDetails: nil, completionTokensDetails: nil)
    _ = TranscriptController.apply(
      .usage(u1, tokensPerSecond: nil),
      to: &state, theme: theme, renderer: renderer,
      followingLive: true, contextWindow: nil)
    let u2 = Components.Schemas.CompletionUsage(
      promptTokens: 20, completionTokens: 10, totalTokens: 30,
      promptTokensDetails: nil, completionTokensDetails: nil)
    _ = TranscriptController.apply(
      .usage(u2, tokensPerSecond: nil),
      to: &state, theme: theme, renderer: renderer,
      followingLive: true, contextWindow: nil)
    #expect(state.usageTurnPrompt == 30)
    #expect(state.usageTurnCompletion == 15)
    #expect(state.usageTurnTotal == 45)
  }

  @Test func usageContextWindowPct() {
    var state = TranscriptState()
    let usage = Components.Schemas.CompletionUsage(
      promptTokens: 2000, completionTokens: 100, totalTokens: 2100,
      promptTokensDetails: nil, completionTokensDetails: nil)
    _ = TranscriptController.apply(
      .usage(usage, tokensPerSecond: nil),
      to: &state, theme: theme, renderer: renderer,
      followingLive: true, contextWindow: 4000)
    #expect(state.usageHUD?.contextWindowUsedPercent == 50)
  }

  // MARK: - .turnComplete

  @Test func turnCompleteFinalizesStreamingState() {
    var state = TranscriptState()
    state.streamingOpenLine = TLine(spans: [StyledSpan(fg: .white, bg: .black, bold: false, text: "remaining")])
    state.streamingOpenLineRaw = "remaining"
    state.streamingSectionStartLineIndex = 0

    _ = TranscriptController.apply(
      .turnComplete(referenceMessages: []),
      to: &state, theme: theme, renderer: renderer,
      followingLive: true, contextWindow: nil)
    #expect(state.streamingOpenLine == nil)
    #expect(state.streamingOpenLineRaw.isEmpty)
    #expect(state.streamingSectionStartLineIndex == nil)
  }

  // MARK: - .skippedUnreadableStreamLine

  @Test func skippedUnreadableStreamLine() {
    var state = TranscriptState()
    let effects = TranscriptController.apply(
      .skippedUnreadableStreamLine, to: &state, theme: theme, renderer: renderer,
      followingLive: true, contextWindow: nil)
    #expect(effects.needsRender)
    #expect(state.lines.count == 1)
    #expect(state.lines[0].spans.map(\.text).joined().contains("skipped"))
  }

  // MARK: - Streaming rendering respects followingLive

  @Test func appendAssistantTextSkipsRenderWhenScrolledUp() {
    var state = TranscriptState()
    // Set up a streaming section
    _ = TranscriptController.apply(
      .enterAssistantSection(.answer, previous: nil),
      to: &state, theme: theme, renderer: renderer,
      followingLive: true, contextWindow: nil)

    // Now append text while NOT following live (user scrolled up)
    let effects = TranscriptController.apply(
      .appendAssistantText(.answer, text: "some text"),
      to: &state, theme: theme, renderer: renderer,
      followingLive: false, contextWindow: nil)
    #expect(!effects.needsRender)
    #expect(state.streamingOpenLineRaw == "some text")
  }

  // MARK: - Idempotency

  @Test func multipleBlankLines() {
    var state = TranscriptState()
    for _ in 0..<5 {
      _ = TranscriptController.apply(
        .blankLine, to: &state, theme: theme, renderer: renderer,
        followingLive: true, contextWindow: nil)
    }
    #expect(state.lines.count == 5)
    #expect(state.lines.allSatisfy { $0.spans.isEmpty })
  }
}
