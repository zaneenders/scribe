import Foundation

/// Hooks for streaming model + tool transcript. The agent loop in ``AgentHarness`` calls these; hosts inject a conforming type (TTY, silent, SwiftUI bridge, etc.).
///
/// Defined in ``ScribeCore`` because the harness lives here. Terminal styling primitives live in ``ScribeTUI`` (ANSI, layouts); the CLI executable composes them into ``TerminalScribeOutput`` conforming to this protocol.
public protocol ScribeAgentOutput: Sendable {
  func printConfigBanner(baseURL: String, model: String, cwd: String)
  func printUserPromptDecoration()

  func enterAssistantStreamSection(_ section: AssistantStreamSection, previous: AssistantStreamSection?)
    throws
  func appendAssistantStreamText(_ section: AssistantStreamSection, text: String) throws
  func finalizeAssistantStreamIfNeeded(streamHadVisibleTokens: Bool) throws
  func printEmptyAssistantTurn() throws

  func emitUsage(promptTokens: Int?, completionTokens: Int?, totalTokens: Int?) throws

  func printBlankLine() throws
  func printToolRoundHeader(round: Int, toolNames: [String]) throws
  func printToolInvocation(name: String, argumentSummary: String?, outputLines: [String]) throws

  func printMaxToolRoundsExceeded(max: Int) throws

  func printSkippedUnreadableStreamLine() throws
  func printHarnessRunError(_ error: Error) throws
}

extension ScribeAgentOutput {
  public func printConfigBanner(baseURL: String, model: String, cwd: String) {}
  public func printUserPromptDecoration() {}
  public func enterAssistantStreamSection(_ section: AssistantStreamSection, previous: AssistantStreamSection?)
    throws
  {}
  public func appendAssistantStreamText(_ section: AssistantStreamSection, text: String) throws {}
  public func finalizeAssistantStreamIfNeeded(streamHadVisibleTokens: Bool) throws {}
  public func printEmptyAssistantTurn() throws {}
  public func emitUsage(promptTokens: Int?, completionTokens: Int?, totalTokens: Int?) throws {}
  public func printBlankLine() throws {}
  public func printToolRoundHeader(round: Int, toolNames: [String]) throws {}
  public func printToolInvocation(name: String, argumentSummary: String?, outputLines: [String]) throws {}
  public func printMaxToolRoundsExceeded(max: Int) throws {}
  public func printSkippedUnreadableStreamLine() throws {}
  public func printHarnessRunError(_ error: Error) throws {}
}
