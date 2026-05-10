import Foundation
import ScribeCore
import SlateCore
import Testing

@testable import ScribeCLI

// MARK: - TranscriptController tests

/// Tests for `TranscriptController` — a pure state machine that builds
/// transcript lines from `TranscriptEvent` values.
@Suite
struct TranscriptControllerTests {

  private let theme = CLITheme.default
  private let renderer: MarkdownRenderer = SwiftMarkdownRenderer()

  // MARK: - User submission

  @Test func userSubmittedAddsYouLine() {
    var controller = TranscriptController()
    controller.apply(.userSubmitted("hello world"), theme: theme, renderer: renderer)

    #expect(controller.completedLines.count >= 2)
    // First line: "you:"
    #expect(controller.completedLines[0].spans.first?.text == "you:")
    // Second line: "  hello world"
    #expect(controller.completedLines[1].spans.first?.text == "  hello world")
    #expect(controller.streamingOpenLine == nil)
    #expect(controller.generation > 0)
  }

  @Test func userSubmittedWithNewlinesCreatesMultipleLines() {
    var controller = TranscriptController()
    controller.apply(.userSubmitted("line1\nline2\nline3"), theme: theme, renderer: renderer)

    // "you:" + "  line1" + "  line2" + "  line3" = 4 lines
    #expect(controller.completedLines.count == 4)
    #expect(controller.completedLines[0].spans.first?.text == "you:")
    #expect(controller.completedLines[1].spans.first?.text == "  line1")
    #expect(controller.completedLines[2].spans.first?.text == "  line2")
    #expect(controller.completedLines[3].spans.first?.text == "  line3")
  }

  @Test func userSubmittedEmptyTextDoesNothing() {
    var controller = TranscriptController()
    controller.apply(.userSubmitted(""), theme: theme, renderer: renderer)

    #expect(controller.completedLines.isEmpty)
    #expect(controller.generation == 0)
  }

  // MARK: - Assistant section

  @Test func enterAssistantSectionAddsHeader() {
    var controller = TranscriptController()
    // First add a user line so we get the separator behavior.
    controller.apply(.userSubmitted("test"), theme: theme, renderer: renderer)
    controller.apply(.enterAssistantSection(.answer, previous: nil), theme: theme, renderer: renderer)

    // Should have: "you:", "  test", "scribe:", "  · answer"
    // (The blank separator only inserts when the last completed line is the "you:" prefix)
    #expect(controller.completedLines.count == 4)
    // Check for scribe prefix.
    let scribeLine = controller.completedLines.first { line in
      line.spans.first?.text == "scribe:"
    }
    #expect(scribeLine != nil)
    // Check for section label.
    let sectionLine = controller.completedLines.first { line in
      line.spans.first?.text == "  · answer"
    }
    #expect(sectionLine != nil)
    // Streaming open line should be initialized.
    #expect(controller.streamingOpenLine != nil)
  }

  // MARK: - Append text

  @Test func appendAssistantTextBuildsStreamingContent() {
    var controller = TranscriptController()
    controller.apply(.userSubmitted("test"), theme: theme, renderer: renderer)
    controller.apply(.enterAssistantSection(.answer, previous: nil), theme: theme, renderer: renderer)
    controller.apply(.appendAssistantText(.answer, text: "Hello"), theme: theme, renderer: renderer)
    controller.apply(.appendAssistantText(.answer, text: ", world!"), theme: theme, renderer: renderer)

    // After streaming, the open line should contain the text.
    #expect(controller.streamingOpenLineRaw == "Hello, world!")
  }

  // MARK: - Finalize

  @Test func finalizeAssistantStreamCommitsOpenLine() {
    var controller = TranscriptController()
    controller.apply(.userSubmitted("test"), theme: theme, renderer: renderer)
    controller.apply(.enterAssistantSection(.answer, previous: nil), theme: theme, renderer: renderer)
    controller.apply(.appendAssistantText(.answer, text: "Hello"), theme: theme, renderer: renderer)
    controller.apply(.finalizeAssistantStream, theme: theme, renderer: renderer)

    // Streaming should be done.
    #expect(controller.streamingOpenLine == nil)
    #expect(controller.streamingOpenLineRaw == "")
    // The text should be in completed lines.
    let allText = controller.completedLines.flatMap { $0.spans }.map { $0.text }.joined()
    #expect(allText.contains("Hello"))
  }

  // MARK: - Tool round

  @Test func toolRoundHeaderAddsHeaderLine() {
    var controller = TranscriptController()
    controller.apply(.toolRoundHeader(round: 1, toolNames: ["read_file", "shell"]), theme: theme, renderer: renderer)

    #expect(controller.completedLines.count == 1)
    let text = controller.completedLines[0].spans.map { $0.text }.joined()
    #expect(text.contains("tool round 1"))
    #expect(text.contains("read_file"))
    #expect(text.contains("shell"))
  }

  @Test func toolInvocationAddsLines() {
    var controller = TranscriptController()
    controller.apply(
      .toolInvocation(name: "read_file", arguments: #"{"path":"/tmp/test.txt"}"#, output: #"{"ok":true}"#),
      theme: theme, renderer: renderer)

    // Should have: "▶ read_file ...", output line(s)
    #expect(controller.completedLines.count >= 1)
    let firstLine = controller.completedLines[0].spans.map { $0.text }.joined()
    #expect(firstLine.contains("▶ read_file"))
    #expect(firstLine.contains("/tmp/test.txt"))
  }

  // MARK: - Error

  @Test func harnessErrorAddsErrorLine() {
    var controller = TranscriptController()
    controller.apply(.harnessError(.generic("something went wrong")), theme: theme, renderer: renderer)

    #expect(controller.completedLines.count == 1)
    let text = controller.completedLines[0].spans.map { $0.text }.joined()
    #expect(text.contains("error:"))
    #expect(text.contains("something went wrong"))
  }

  // MARK: - Interrupted

  @Test func turnInterruptedAddsInterruptedLine() {
    var controller = TranscriptController()
    controller.apply(.turnInterrupted, theme: theme, renderer: renderer)

    #expect(controller.completedLines.count == 1)
    let text = controller.completedLines[0].spans.map { $0.text }.joined()
    #expect(text.contains("(interrupted)"))
    #expect(controller.streamingOpenLine == nil)
    #expect(controller.streamingOpenLineRaw == "")
  }

  // MARK: - Empty assistant turn

  @Test func emptyAssistantTurnAddsPlaceholder() {
    var controller = TranscriptController()
    controller.apply(.emptyAssistantTurn, theme: theme, renderer: renderer)

    #expect(controller.completedLines.count == 2)
    let text = controller.completedLines.flatMap { $0.spans }.map { $0.text }.joined()
    #expect(text.contains("scribe:"))
    #expect(text.contains("(empty turn)"))
  }

  // MARK: - Blank line

  @Test func blankLineAddsEmptyLine() {
    var controller = TranscriptController()
    controller.apply(.blankLine, theme: theme, renderer: renderer)

    #expect(controller.completedLines.count == 1)
    #expect(controller.completedLines[0].spans.isEmpty)
  }

  // MARK: - applyAll

  @Test func applyAllReturnsHistory() {
    var controller = TranscriptController()
    let events: [TranscriptEvent] = [
      .userSubmitted("one"),
      .blankLine,
      .userSubmitted("two"),
    ]

    let history = controller.applyAll(events, theme: theme, renderer: renderer)

    #expect(history.count == 3)
    #expect(controller.completedLines.count > 0)

    // Each snapshot should reflect the state after its event.
    if case .userSubmitted(let text) = history[0].event {
      #expect(text == "one")
    } else {
      #expect(Bool(false))
    }
  }
}
