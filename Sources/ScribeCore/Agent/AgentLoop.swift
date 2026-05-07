import Foundation
import Logging
import ScribeLLM

/// Orchestrates the interaction between ``AgentHarness`` (LLM loop) and ``ToolRegistry`` (tool
/// execution), driving multi-round model turns.
///
/// Consumes ``RoundStream`` values from the harness and emits tool events
/// into a combined ``TurnStream``.
public struct AgentLoop: Sendable {
  private let harness: any AgentHarnessProtocol
  private let registry: ToolRegistry

  public init(
    harness: any AgentHarnessProtocol,
    registry: ToolRegistry
  ) {
    self.harness = harness
    self.registry = registry
  }

  public func runModelStreamingTurn(
    messages: [Components.Schemas.ChatMessage],
    logger: Logger,
    temperature: Double,
    maxToolRounds: Int = .max,
    shouldAbortTurn: @escaping @Sendable () -> Bool = { false }
  ) -> TurnStream {
    let (stream, continuation) = AsyncStream<TranscriptEvent>.makeStream()
    var mutable = messages

    let task = Task {
      defer { continuation.finish() }
      let clock = ContinuousClock()
      logger.debug(
        "agent.turn.start",
        metadata: [
          "model": "\(harness.model)",
          "messages": "\(mutable.count)",
        ])
      var round = 0
      while true {
        round += 1
        if shouldAbortTurn() {
          logger.debug("agent.abort", metadata: ["where": "before-http", "round": "\(round)"])
          return TurnResult(messages: mutable, outcome: .interrupted)
        }

        let messagesCountBeforeRound = mutable.count

        let roundStream = harness.runStreamingRound(
          messages: mutable,
          logger: logger,
          temperature: temperature,
          shouldAbortTurn: shouldAbortTurn
        )

        // Forward all harness events
        for await event in roundStream.events {
          continuation.yield(event)
        }

        let roundResult: RoundResult
        do {
          roundResult = try await roundStream.result.value
        } catch is AgentTurnInterruptedError {
          return TurnResult(messages: mutable, outcome: .interrupted)
        } catch {
          throw error
        }

        mutable = roundResult.messages

        if shouldAbortTurn() {
          logger.debug(
            "agent.abort",
            metadata: ["where": "post-stream-pre-tools", "round": "\(round)"])
          mutable.removeSubrange(messagesCountBeforeRound..<mutable.endIndex)
          return TurnResult(messages: mutable, outcome: .interrupted)
        }

        switch roundResult.outcome {
        case .completed:
          return TurnResult(messages: mutable, outcome: .completed)

        case .toolCalls(let invocations):
          if round >= maxToolRounds {
            logger.notice("event=agent.turn.tool-round-limit max=\(maxToolRounds)")
            mutable.removeSubrange(messagesCountBeforeRound..<mutable.endIndex)
            return TurnResult(messages: mutable, outcome: .toolRoundLimit(rounds: maxToolRounds))
          }

          logger.info(
            "agent.tool.round",
            metadata: [
              "round": "\(round)",
              "tool_count": "\(invocations.count)",
              "tools": "\(invocations.map(\.name).joined(separator: ","))",
            ])
          continuation.yield(.toolRoundHeader(round: round, toolNames: invocations.map(\.name)))

          for inv in invocations {
            // TODO: Parallel tool calls?
            if shouldAbortTurn() {
              logger.notice(
                "agent.abort",
                metadata: ["where": "pre-tool", "tool": "\(inv.name)", "round": "\(round)"])
              mutable.removeSubrange(messagesCountBeforeRound..<mutable.endIndex)
              return TurnResult(messages: mutable, outcome: .interrupted)
            }
            let toolStarted = clock.now
            let jsonOutput: String
            do {
              jsonOutput = try await registry.run(
                name: inv.name,
                arguments: inv.arguments,
                abortVia: shouldAbortTurn
              )
            } catch is AgentTurnInterruptedError {
              mutable.removeSubrange(messagesCountBeforeRound..<mutable.endIndex)
              return TurnResult(messages: mutable, outcome: .interrupted)
            }
            let elapsedMs = Int(toolStarted.duration(to: clock.now) / .milliseconds(1))
            let unknown = jsonOutput.contains("unknown tool")
            if unknown {
              logger.warning("agent.tool.unknown", metadata: ["tool": "\(inv.name)", "round": "\(round)"])
            }
            logger.debug(
              "agent.tool.invoke",
              metadata: [
                "round": "\(round)", "tool": "\(inv.name)",
                "args_chars": "\(inv.arguments.count)",
                "output_chars": "\(jsonOutput.count)",
                "elapsed_ms": "\(elapsedMs)", "unknown": "\(unknown)",
              ])
            continuation.yield(.toolInvocation(name: inv.name, arguments: inv.arguments, output: jsonOutput))
            continuation.yield(.blankLine)
            let toolMsg = Components.Schemas.ChatMessage(
              role: .tool,
              content: jsonOutput,
              name: nil,
              toolCalls: nil,
              toolCallId: inv.id
            )
            mutable.append(toolMsg)
          }
        }
      }
    }

    return TurnStream(events: stream, result: task)
  }
}
