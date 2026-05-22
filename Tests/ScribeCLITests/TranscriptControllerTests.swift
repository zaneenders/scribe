import Foundation
import ScribeCore
import Testing

@testable import ScribeCLI

// MARK: - TranscriptController tests

/// Tests for the `TranscriptController` pure state machine — every event arm
/// is exercised without a running TUI, Slate, or async machinery.
@Suite
struct TranscriptControllerTests {

  private let theme = CLITheme.default
  private let renderer: MarkdownRenderer = SwiftMarkdownRenderer()

  // MARK: - applyUserSubmitted (direct call — no longer a AgentEvent)

  @Test func userSubmittedProducesYouPrefix() {
    var state = TranscriptState()
    let effects = TranscriptController.applyUserSubmitted("hello", state: &state, theme: theme)
    #expect(effects.needsRender)
    #expect(state.lines.count == 2)
    #expect(state.lines[0].spans[0].text == "you:")
    #expect(state.lines[1].spans[0].text.contains("hello"))
  }

  @Test func userSubmittedEmptyNoOp() {
    var state = TranscriptState()
    let effects = TranscriptController.applyUserSubmitted("", state: &state, theme: theme)
    #expect(!effects.needsRender)
    #expect(state.lines.isEmpty)
  }

  @Test func userSubmittedMultiLine() {
    var state = TranscriptState()
    let effects = TranscriptController.applyUserSubmitted("hello\nworld", state: &state, theme: theme)
    #expect(effects.needsRender)
    #expect(state.lines.count == 3)  // "you:" + "  hello" + "  world"
    #expect(state.lines[0].spans[0].text == "you:")
    #expect(state.lines[1].spans[0].text.contains("hello"))
    #expect(state.lines[2].spans[0].text.contains("world"))
  }

  // MARK: - .toolInvocation (blank line now appended internally)

  @Test func toolInvocationAppendsTrailingBlankLine() {
    var state = TranscriptState()
    let effects = TranscriptController.apply(
      .tool(.invocation(
        name: "shell", arguments: #"{"command":"ls"}"#,
        output: #"{"ok":true,"stdout":"file.txt\n","exitCode":0}"#)),
      to: &state, theme: theme, renderer: renderer,
      followingLive: true, contextWindow: nil)
    #expect(effects.needsRender)
    #expect(state.lines.count >= 2)
    // Last line should be the blank separator appended by the controller.
    #expect(state.lines.last?.spans.isEmpty == true)
    let firstLine = state.lines[0].spans.map(\.text).joined()
    #expect(firstLine.contains("shell"))
  }

  // MARK: - .harnessError

  @Test func harnessError() {
    var state = TranscriptState()
    let effects = TranscriptController.apply(
      .lifecycle(.error(.generic("test error"))),
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
      .lifecycle(.interrupted), to: &state, theme: theme, renderer: renderer,
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
      .output(.empty), to: &state, theme: theme, renderer: renderer,
      followingLive: true, contextWindow: nil)
    #expect(effects.needsRender)
    #expect(state.lines.count == 2)
    #expect(state.lines[0].spans[0].text == "scribe:")
    #expect(state.lines[1].spans[0].text == "(empty turn)")
  }

  // MARK: - .enterAssistantSection

  @Test func enterAssistantSectionAnswer() {
    var state = TranscriptState()
    _ = TranscriptController.applyUserSubmitted("test", state: &state, theme: theme)

    let effects = TranscriptController.apply(
      .output(.sectionStarted(.answer, previous: nil)),
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
    _ = TranscriptController.applyUserSubmitted("test", state: &state, theme: theme)

    let effects = TranscriptController.apply(
      .output(.sectionStarted(.reasoning, previous: nil)),
      to: &state, theme: theme, renderer: renderer,
      followingLive: true, contextWindow: nil)
    #expect(effects.needsRender)
    let labelLine = state.lines.last?.spans[0].text
    #expect(labelLine == "  · reasoning")
  }

  // MARK: - .finalizeAssistantStream (blank line now appended internally)

  @Test func finalizeAssistantStreamAppendsTrailingBlankLine() {
    var state = TranscriptState()
    _ = TranscriptController.apply(
      .output(.sectionStarted(.answer, previous: nil)),
      to: &state, theme: theme, renderer: renderer, followingLive: true, contextWindow: nil)
    _ = TranscriptController.apply(
      .output(.text(.answer, "hello")),
      to: &state, theme: theme, renderer: renderer, followingLive: true, contextWindow: nil)
    _ = TranscriptController.apply(
      .output(.finalized),
      to: &state, theme: theme, renderer: renderer, followingLive: true, contextWindow: nil)
    // Last line should be the blank separator.
    #expect(state.lines.last?.spans.isEmpty == true)
  }

  // MARK: - .usage

  @Test func usageUpdatesHUD() {
    var state = TranscriptState()
    let usage = ScribeUsage(promptTokens: 100, completionTokens: 50, totalTokens: 150)
    let effects = TranscriptController.apply(
      .lifecycle(.usage(usage, tokensPerSecond: 10.5)),
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
    let u1 = ScribeUsage(promptTokens: 10, completionTokens: 5, totalTokens: 15)
    _ = TranscriptController.apply(
      .lifecycle(.usage(u1, tokensPerSecond: nil)),
      to: &state, theme: theme, renderer: renderer,
      followingLive: true, contextWindow: nil)
    let u2 = ScribeUsage(promptTokens: 20, completionTokens: 10, totalTokens: 30)
    _ = TranscriptController.apply(
      .lifecycle(.usage(u2, tokensPerSecond: nil)),
      to: &state, theme: theme, renderer: renderer,
      followingLive: true, contextWindow: nil)
    #expect(state.usageTurnPrompt == 30)
    #expect(state.usageTurnCompletion == 15)
    #expect(state.usageTurnTotal == 45)
  }

  @Test func usageContextWindowPct() {
    var state = TranscriptState()
    let usage = ScribeUsage(promptTokens: 2000, completionTokens: 100, totalTokens: 2100)
    _ = TranscriptController.apply(
      .lifecycle(.usage(usage, tokensPerSecond: nil)),
      to: &state, theme: theme, renderer: renderer,
      followingLive: true, contextWindow: 4000)
    #expect(state.usageHUD?.contextWindowUsedPercent == 50)
  }

  // MARK: - Streaming rendering respects followingLive

  @Test func appendAssistantTextSkipsRenderWhenScrolledUp() {
    var state = TranscriptState()
    _ = TranscriptController.apply(
      .output(.sectionStarted(.answer, previous: nil)),
      to: &state, theme: theme, renderer: renderer,
      followingLive: true, contextWindow: nil)

    let effects = TranscriptController.apply(
      .output(.text(.answer, "some text")),
      to: &state, theme: theme, renderer: renderer,
      followingLive: false, contextWindow: nil)
    #expect(!effects.needsRender)
    #expect(state.streamingOpenLineRaw == "some text")
  }
}
