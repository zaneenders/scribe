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
      """
      event=agent.turn.start \
      model=\(harness.model) \
      messages=\(messages.count)
      """
    )
    var round = 0
    while true {
      round += 1
      if shouldAbortTurn() {
        logger.debug(
          """
          event=agent.abort \
          where=before-http \
          round=\(round)
          """
        )
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
          """
          event=agent.abort \
          where=post-stream-pre-tools \
          round=\(round)
          """
        )
        throw AgentTurnInterruptedError()
      }

      switch roundOutcome {
      case .completed:
        return .completed

      case .toolCalls(let invocations):
        logger.info(
          """
          event=agent.tool.round \
          round=\(round) \
          tool_count=\(invocations.count) \
          tools=\(invocations.map(\.name).joined(separator: ","))
          """
        )
        onEvent(.toolRoundHeader(round: round, toolNames: invocations.map(\.name)))

        for inv in invocations {
          if shouldAbortTurn() {
            logger.notice(
              """
              event=agent.abort \
              where=pre-tool \
              tool=\(inv.name) \
              round=\(round)
              """
            )
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
              """
              event=agent.tool.invoking \
              tool=\(inv.name) \
              round=\(round) \
              args_chars=\(inv.arguments.count)
              """)
            jsonOutput = try await registry.run(
              name: inv.name,
              arguments: inv.arguments,
              abortVia: shouldAbortTurn
            )
            let elapsedMs = Int(Date().timeIntervalSince(toolStarted) * 1000)
            logger.trace(
              """
              event=agent.tool.invoked \
              tool=\(inv.name) \
              round=\(round) \
              elapsed_ms=\(elapsedMs) \
              output_chars=\(jsonOutput.count)
              """)
          } catch is AgentTurnInterruptedError {
            let abortMs = Int(Date().timeIntervalSince(toolStarted) * 1000)
            logger.notice(
              """
              event=agent.abort \
              where=mid-tool \
              tool=\(inv.name) \
              round=\(round) \
              until_abort_ms=\(abortMs)
              """
            )
            messages.removeSubrange(messagesCountBeforeRound..<messages.endIndex)
            throw AgentTurnInterruptedError()
          }
          let elapsedMs = Int(Date().timeIntervalSince(toolStarted) * 1000)
          let unknown = jsonOutput.contains("unknown tool")
          if unknown {
            logger.warning(
              """
              event=agent.tool.unknown \
              tool=\(inv.name) \
              round=\(round)
              """
            )
          }
          logger.debug(
            """
            event=agent.tool.invoke \
            round=\(round) \
            tool=\(inv.name) \
            args_chars=\(inv.arguments.count) \
            args="\(inv.arguments.logSafe())" \
            output_chars=\(jsonOutput.count) \
            elapsed_ms=\(elapsedMs) \
            unknown=\(unknown)
            """
          )
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
          """
          event=agent.tool.round.end \
          round=\(round) \
          messages=\(messages.count)
          """
        )
      }
    }
  }
}
