import Foundation
import ScribeCore
import Testing

@testable import ScribeCLI

// MARK: - ChatDriver tests

/// Tests for the headless `ChatDriver` — verifies the full event→transcript
/// pipeline without Slate or a terminal.
@Suite
struct ChatDriverTests {

  private let theme = CLITheme.default
  private let renderer: MarkdownRenderer = SwiftMarkdownRenderer()

  // MARK: - Single turn: user → assistant (streaming)

  @Test func fullStreamingTurn() {
    var driver = ChatDriver(renderer: renderer, theme: theme)

    driver.handleUserSubmitted("hello")
    driver.handle(TranscriptEvent.enterAssistantSection(.answer, previous: nil))
    driver.handle(TranscriptEvent.appendAssistantText(.answer, text: "Hello! How can I help?"))
    driver.handle(TranscriptEvent.finalizeAssistantStream)

    #expect(driver.state.lines.count > 0)
    let allText = driver.state.lines.flatMap { $0.spans.map(\.text) }.joined()
    #expect(allText.contains("you:"))
    #expect(allText.contains("hello"))
    #expect(allText.contains("Hello! How can I help?"))
  }

  // MARK: - Tool invocation

  @Test func toolInvocationTurn() {
    var driver = ChatDriver(renderer: renderer, theme: theme)

    driver.handleUserSubmitted("list files")
    driver.handle(TranscriptEvent.enterAssistantSection(.answer, previous: nil))
    driver.handle(TranscriptEvent.appendAssistantText(.answer, text: "Let me check"))
    driver.handle(TranscriptEvent.finalizeAssistantStream)
    driver.handle(
      TranscriptEvent.toolInvocation(
        name: "shell",
        arguments: #"{"command":"ls"}"#,
        output: #"{"ok":true,"stdout":"file.txt\n","exitCode":0}"#
      ))

    let allText = driver.state.lines.flatMap { $0.spans.map(\.text) }.joined()
    #expect(allText.contains("shell"))
    #expect(allText.contains("list files"))
  }

  // MARK: - Reasoning section

  @Test func reasoningThenAnswer() {
    var driver = ChatDriver(renderer: renderer, theme: theme)

    driver.handleUserSubmitted("complex question")
    driver.handle(TranscriptEvent.enterAssistantSection(.reasoning, previous: nil))
    driver.handle(TranscriptEvent.appendAssistantText(.reasoning, text: "Let me think..."))
    driver.handle(TranscriptEvent.finalizeAssistantStream)
    driver.handle(TranscriptEvent.enterAssistantSection(.answer, previous: .reasoning))
    driver.handle(TranscriptEvent.appendAssistantText(.answer, text: "The answer is 42"))
    driver.handle(TranscriptEvent.finalizeAssistantStream)

    let allText = driver.state.lines.flatMap { $0.spans.map(\.text) }.joined()
    #expect(allText.contains("reasoning"))
    #expect(allText.contains("answer"))
    #expect(allText.contains("Let me think"))
    #expect(allText.contains("The answer is 42"))
  }

  // MARK: - Interrupt handling

  @Test func turnInterruptedClearsStreaming() {
    var driver = ChatDriver(renderer: renderer, theme: theme)

    driver.handleUserSubmitted("long task")
    driver.handle(TranscriptEvent.enterAssistantSection(.answer, previous: nil))
    driver.handle(TranscriptEvent.appendAssistantText(.answer, text: "Working..."))
    driver.handle(TranscriptEvent.turnInterrupted)

    #expect(driver.state.streamingOpenLine == nil)
    #expect(driver.state.streamingOpenLineRaw.isEmpty)
    let allText = driver.state.lines.flatMap { $0.spans.map(\.text) }.joined()
    #expect(allText.contains("(interrupted)"))
  }

  // MARK: - Usage accumulation

  @Test func usageAccumulatesAcrossMultipleRounds() {
    var driver = ChatDriver(renderer: renderer, theme: theme, contextWindow: 8000)

    let u1 = ScribeUsage(promptTokens: 100, completionTokens: 50, totalTokens: 150)
    let u2 = ScribeUsage(promptTokens: 200, completionTokens: 75, totalTokens: 275)

    driver.handle(TranscriptEvent.usage(u1, tokensPerSecond: nil))
    driver.handle(TranscriptEvent.usage(u2, tokensPerSecond: nil))

    #expect(driver.state.usageTurnPrompt == 300)
    #expect(driver.state.usageTurnTotal == 425)
    #expect(driver.state.usageSessionPrompt == 300)
  }

  // MARK: - Empty assistant turn

  @Test func emptyAssistantTurn() {
    var driver = ChatDriver(renderer: renderer, theme: theme)

    driver.handleUserSubmitted("do nothing")
    driver.handle(TranscriptEvent.emptyAssistantTurn)

    let allText = driver.state.lines.flatMap { $0.spans.map(\.text) }.joined()
    #expect(allText.contains("(empty turn)"))
  }
}
