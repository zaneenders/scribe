import Foundation
import ScribeLLM

/// Hooks for streaming model + tool transcript. The agent loop in ``AgentHarness`` calls these; hosts inject a conforming type (TTY, silent, SwiftUI bridge, etc.).
///
/// Defined in ``ScribeCore`` because the harness lives here; concrete sinks (e.g. Slate grid + CSI line output in the CLI target) implement this protocol.
public protocol ScribeAgentOutput: Sendable {
  func printConfigBanner(baseURL: String, model: String, cwd: String)
  func printUserPromptDecoration()

  func enterAssistantStreamSection(
    _ section: AssistantStreamSection,
    previous: AssistantStreamSection?
  ) throws
  func appendAssistantStreamText(_ section: AssistantStreamSection, text: String) throws
  func finalizeAssistantStreamIfNeeded(streamHadVisibleTokens: Bool) throws
  func printEmptyAssistantTurn() throws

  /// - Parameters:
  ///   - usage: Usage for the most recent model HTTP response in this harness step (one streaming completion).
  ///   - outputTokensPerSecond: Throughput for that same response only (wall time from first token to stream end).
  func emitUsage(
    usage: Components.Schemas.CompletionUsage?,
    outputTokensPerSecond: Double?
  ) throws

  func printBlankLine() throws
  func printToolRoundHeader(round: Int, toolNames: [String]) throws
  func printToolInvocation(name: String, argumentSummary: String?, outputLines: [String]) throws

  func printMaxToolRoundsExceeded(max: Int) throws

  func printSkippedUnreadableStreamLine() throws
  func printHarnessRunError(_ error: Error) throws
  func printTurnInterrupted() throws

  /// Called around each ``AgentHarness/runModelTurn(messages:logger:)`` so hosts can disable input or show activity.
  func markModelTurnRunning(_ running: Bool) throws
}

extension ScribeAgentOutput {
  public func printConfigBanner(baseURL: String, model: String, cwd: String) {}
  public func printUserPromptDecoration() {}
  public func enterAssistantStreamSection(
    _ section: AssistantStreamSection,
    previous: AssistantStreamSection?
  ) throws {}
  public func appendAssistantStreamText(_ section: AssistantStreamSection, text: String) throws {}
  public func finalizeAssistantStreamIfNeeded(streamHadVisibleTokens: Bool) throws {}
  public func printEmptyAssistantTurn() throws {}
  public func emitUsage(
    usage: Components.Schemas.CompletionUsage?,
    outputTokensPerSecond: Double?
  ) throws {}
  public func printBlankLine() throws {}
  public func printToolRoundHeader(round: Int, toolNames: [String]) throws {}
  public func printToolInvocation(name: String, argumentSummary: String?, outputLines: [String]) throws {}
  public func printMaxToolRoundsExceeded(max: Int) throws {}
  public func printSkippedUnreadableStreamLine() throws {}
  public func printHarnessRunError(_ error: Error) throws {}
  public func printTurnInterrupted() throws {}
  public func markModelTurnRunning(_ running: Bool) throws {}
}
