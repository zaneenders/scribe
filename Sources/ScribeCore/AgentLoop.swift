import Foundation
import Logging
import ScribeLLM

/// Orchestrates the interaction between ``AgentHarness`` (LLM loop) and ``ToolRegistry`` (tool
/// execution), driving multi-round model turns.
public struct AgentLoop: Sendable {
  private let harness: any AgentHarnessProtocol
  private let registry: ToolRegistry
  private let onEvent: @Sendable (TranscriptEvent) -> Void

  public init(
    harness: any AgentHarnessProtocol,
    registry: ToolRegistry,
    onEvent: @escaping @Sendable (TranscriptEvent) -> Void
  ) {
    self.harness = harness
    self.registry = registry
    self.onEvent = onEvent
  }

  public func runModelTurn(
    messages: inout [Components.Schemas.ChatMessage],
    logger: Logger,
    shouldAbortTurn: @escaping @Sendable () -> Bool = { false }
  ) async throws -> ModelTurnOutcome {
    logger.debug(
      "agent.turn.start",
      metadata: [
        "model": "\(harness.model)",
        "messages": "\(messages.count)",
      ])
    var round = 0
    while true {
      round += 1
      if shouldAbortTurn() {
        logger.debug(
          "agent.abort",
          metadata: [
            "where": "before-http",
            "round": "\(round)",
          ])
        throw AgentTurnInterruptedError()
      }

      let messagesCountBeforeRound = messages.count

      let roundOutcome = try await harness.runRound(
        messages: &messages,
        logger: logger,
        shouldAbortTurn: shouldAbortTurn
      )

      if shouldAbortTurn() {
        logger.debug(
          "agent.abort",
          metadata: [
            "where": "post-stream-pre-tools",
            "round": "\(round)",
          ])
        throw AgentTurnInterruptedError()
      }

      switch roundOutcome {
      case .completed:
        return .completed

      case .toolCalls(let invocations):
        logger.info(
          "agent.tool.round",
          metadata: [
            "round": "\(round)",
            "tool_count": "\(invocations.count)",
            "tools": "\(invocations.map(\.name).joined(separator: ","))",
          ])
        onEvent(.toolRoundHeader(round: round, toolNames: invocations.map(\.name)))

        for inv in invocations {
          if shouldAbortTurn() {
            logger.notice(
              "agent.abort",
              metadata: [
                "where": "pre-tool",
                "tool": "\(inv.name)",
                "round": "\(round)",
              ])
            messages.removeSubrange(messagesCountBeforeRound..<messages.endIndex)
            throw AgentTurnInterruptedError()
          }
          let toolStarted = Date()
          // ToolRegistry.run(name:arguments:abortVia:) wraps the
          // tool in a task group that polls shouldAbortTurn so long-running
          // commands (e.g. shell builds) can be cancelled cooperatively.
          let jsonOutput: String
          do {
            logger.trace(
              "agent.tool.invoking",
              metadata: [
                "tool": "\(inv.name)",
                "round": "\(round)",
                "args_chars": "\(inv.arguments.count)",
              ])
            jsonOutput = try await registry.run(
              name: inv.name,
              arguments: inv.arguments,
              abortVia: shouldAbortTurn
            )
            let elapsedMs = Int(Date().timeIntervalSince(toolStarted) * 1000)
            logger.trace(
              "agent.tool.invoked",
              metadata: [
                "tool": "\(inv.name)",
                "round": "\(round)",
                "elapsed_ms": "\(elapsedMs)",
                "output_chars": "\(jsonOutput.count)",
              ])
          } catch is AgentTurnInterruptedError {
            let abortMs = Int(Date().timeIntervalSince(toolStarted) * 1000)
            logger.notice(
              "agent.abort",
              metadata: [
                "where": "mid-tool",
                "tool": "\(inv.name)",
                "round": "\(round)",
                "until_abort_ms": "\(abortMs)",
              ])
            messages.removeSubrange(messagesCountBeforeRound..<messages.endIndex)
            throw AgentTurnInterruptedError()
          }
          let elapsedMs = Int(Date().timeIntervalSince(toolStarted) * 1000)
          let unknown = jsonOutput.contains("unknown tool")
          if unknown {
            logger.warning(
              "agent.tool.unknown",
              metadata: [
                "tool": "\(inv.name)",
                "round": "\(round)",
              ])
          }
          logger.debug(
            "agent.tool.invoke",
            metadata: [
              "round": "\(round)",
              "tool": "\(inv.name)",
              "args_chars": "\(inv.arguments.count)",
              "args": "\(inv.arguments.logSafe())",
              "output_chars": "\(jsonOutput.count)",
              "elapsed_ms": "\(elapsedMs)",
              "unknown": "\(unknown)",
            ])
          onEvent(.toolInvocation(name: inv.name, arguments: inv.arguments, output: jsonOutput))
          onEvent(.blankLine)
          let toolMsg = Components.Schemas.ChatMessage(
            role: .tool,
            content: jsonOutput,
            name: nil,
            toolCalls: nil,
            toolCallId: inv.id
          )
          messages.append(toolMsg)
        }
        logger.trace(
          "agent.tool.round.end",
          metadata: [
            "round": "\(round)",
            "messages": "\(messages.count)",
          ])
      }
    }
  }
}
