import Foundation
import ScribeCore
import Testing

@testable import ScribeCLI
@testable import ScribeKit

@Suite
struct ChatDriverTests {

  private let theme = CLITheme.default
  private let renderer: MarkdownRenderer = SwiftMarkdownRenderer()

  @Test func fullStreamingTurn() {
    var driver = ChatDriver(renderer: renderer, theme: theme)

    driver.handleUserSubmitted("hello")
    driver.handle(AgentEvent.output(.sectionStarted(.answer, previous: nil)))
    driver.handle(AgentEvent.output(.text(.answer, "Hello! How can I help?")))
    driver.handle(AgentEvent.output(.finalized))

    #expect(driver.state.lines.count > 0)
    let allText = driver.state.lines.flatMap { $0.spans.map(\.text) }.joined()
    #expect(allText.contains("you:"))
    #expect(allText.contains("hello"))
    #expect(allText.contains("Hello! How can I help?"))
  }

  @Test func toolInvocationTurn() {
    var driver = ChatDriver(renderer: renderer, theme: theme)

    driver.handleUserSubmitted("list files")
    driver.handle(AgentEvent.output(.sectionStarted(.answer, previous: nil)))
    driver.handle(AgentEvent.output(.text(.answer, "Let me check")))
    driver.handle(AgentEvent.output(.finalized))
    driver.handle(
      AgentEvent.tool(
        .invocation(
          name: "shell",
          arguments: #"{"command":"ls"}"#,
          output: #"{"ok":true,"stdout":"file.txt\n","exitCode":0}"#
        )))

    let allText = driver.state.lines.flatMap { $0.spans.map(\.text) }.joined()
    #expect(allText.contains("shell"))
    #expect(allText.contains("list files"))
  }

  @Test func reasoningThenAnswer() {
    var driver = ChatDriver(renderer: renderer, theme: theme)

    driver.handleUserSubmitted("complex question")
    driver.handle(AgentEvent.output(.sectionStarted(.reasoning, previous: nil)))
    driver.handle(AgentEvent.output(.text(.reasoning, "Let me think...")))
    driver.handle(AgentEvent.output(.finalized))
    driver.handle(AgentEvent.output(.sectionStarted(.answer, previous: .reasoning)))
    driver.handle(AgentEvent.output(.text(.answer, "The answer is 42")))
    driver.handle(AgentEvent.output(.finalized))

    let allText = driver.state.lines.flatMap { $0.spans.map(\.text) }.joined()
    #expect(allText.contains("reasoning"))
    #expect(allText.contains("answer"))
    #expect(allText.contains("Let me think"))
    #expect(allText.contains("The answer is 42"))
  }

  @Test func turnInterruptedClearsStreaming() {
    var driver = ChatDriver(renderer: renderer, theme: theme)

    driver.handleUserSubmitted("long task")
    driver.handle(AgentEvent.output(.sectionStarted(.answer, previous: nil)))
    driver.handle(AgentEvent.output(.text(.answer, "Working...")))
    driver.handle(AgentEvent.lifecycle(.interrupted))

    #expect(driver.state.streamingOpenLine == nil)
    #expect(driver.state.streamingOpenLineRaw.isEmpty)
    let allText = driver.state.lines.flatMap { $0.spans.map(\.text) }.joined()
    #expect(allText.contains("(interrupted)"))
  }

  @Test func usageAccumulatesAcrossMultipleRounds() {
    var driver = ChatDriver(renderer: renderer, theme: theme, contextWindow: 8000)

    let u1 = ScribeUsage(promptTokens: 100, completionTokens: 50, totalTokens: 150)
    let u2 = ScribeUsage(promptTokens: 200, completionTokens: 75, totalTokens: 275)

    driver.handle(AgentEvent.lifecycle(.usage(u1, tokensPerSecond: nil)))
    driver.handle(AgentEvent.lifecycle(.usage(u2, tokensPerSecond: nil)))

    #expect(driver.state.usageTurnPrompt == 300)
    #expect(driver.state.usageTurnTotal == 425)
    #expect(driver.state.usageSessionPrompt == 300)
  }

  @Test func emptyAssistantTurn() {
    var driver = ChatDriver(renderer: renderer, theme: theme)

    driver.handleUserSubmitted("do nothing")
    driver.handle(AgentEvent.output(.empty))

    let allText = driver.state.lines.flatMap { $0.spans.map(\.text) }.joined()
    #expect(allText.contains("(empty turn)"))
  }
}
