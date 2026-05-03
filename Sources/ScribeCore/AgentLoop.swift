import Foundation
import Logging
import ScribeLLM

/// Orchestrates the interaction between ``AgentHarness`` (LLM loop) and ``ToolRegistry`` (tool
/// execution), driving multi-round model turns.
public struct AgentLoop: Sendable {
  private let harness: any AgentHarnessProtocol
  private let registry: ToolRegistry
  private let maxToolRounds: Int
  private let onEvent: @Sendable (TranscriptEvent) -> Void

  public init(
    harness: any AgentHarnessProtocol,
    registry: ToolRegistry,
    maxToolRounds: Int,
    onEvent: @escaping @Sendable (TranscriptEvent) -> Void
  ) {
    self.harness = harness
    self.registry = registry
    self.maxToolRounds = maxToolRounds
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
      messages=\(messages.count) \
      max_tool_rounds=\(maxToolRounds)
      """
    )
    for round in 0..<maxToolRounds {
      let roundNum = round + 1
      if shouldAbortTurn() {
        logger.debug(
          """
          event=agent.abort \
          where=before-http \
          round=\(roundNum)
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
          round=\(roundNum)
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
          round=\(roundNum) \
          tool_count=\(invocations.count) \
          tools=\(invocations.map(\.name).joined(separator: ","))
          """
        )
        onEvent(.toolRoundHeader(round: roundNum, toolNames: invocations.map(\.name)))

        for inv in invocations {
          if shouldAbortTurn() {
            logger.notice(
              """
              event=agent.abort \
              where=pre-tool \
              tool=\(inv.name) \
              round=\(roundNum)
              """
            )
            messages.removeSubrange(messagesCountBeforeRound..<messages.endIndex)
            throw AgentTurnInterruptedError()
          }
          let toolStarted = Date()
          let jsonOutput = await registry.run(name: inv.name, arguments: inv.arguments)
          let elapsedMs = Int(Date().timeIntervalSince(toolStarted) * 1000)
          let unknown = jsonOutput.contains("unknown tool")
          if unknown {
            logger.warning(
              """
              event=agent.tool.unknown \
              tool=\(inv.name) \
              round=\(roundNum)
              """
            )
          }
          logger.debug(
            """
            event=agent.tool.invoke \
            round=\(roundNum) \
            tool=\(inv.name) \
            args_chars=\(inv.arguments.count) \
            output_chars=\(jsonOutput.count) \
            elapsed_ms=\(elapsedMs) \
            unknown=\(unknown)
            """
          )
          // Tool-specific structured detail. Right now only `read_file` carries enough
          // metadata to be worth a dedicated log line, but the same pattern can be extended
          // to other tools (`shell` exit code, `edit_file` chars-replaced, etc.) without
          // changing the loop's main control flow.
          if inv.name == "read_file" {
            let summary = ToolInvocationFormatting.readFileLogSummary(jsonOutput: jsonOutput)
            logger.debug(
              """
              event=agent.tool.read_file \
              round=\(roundNum) \
              \(summary)
              """
            )
          }
          let argSummary = ToolInvocationFormatting.argumentSummary(
            name: inv.name, argumentsJSON: inv.arguments)
          let lines = ToolInvocationFormatting.outputLines(name: inv.name, jsonOutput: jsonOutput)
          onEvent(.toolInvocation(name: inv.name, argumentSummary: argSummary, outputLines: lines))
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
          round=\(roundNum) \
          messages=\(messages.count)
          """
        )
      }
    }
    logger.notice(
      """
      event=agent.turn.tool-round-limit \
      max=\(maxToolRounds)
      """
    )
    onEvent(.maxToolRoundsExceeded(max: maxToolRounds))
    return .hitToolRoundLimit
  }
}
