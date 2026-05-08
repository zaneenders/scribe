import Foundation
import Logging
import ScribeLLM

// MARK: - ScribeAgent

/// An agent that executes LLM turns with tool execution.
///
/// Instantiate with a `ScribeConfig` (or a harness for testing), then call `streamTurn`.
public struct ScribeAgent: Sendable {
  private let harness: any AgentHarnessProtocol

  /// Creates an agent from a `ScribeConfig`. Throws `ScribeError.configuration`
  /// if `serverURL` cannot be parsed into a `URL`.
  public static func make(configuration: ScribeConfig) throws -> ScribeAgent {
    guard let serverURL = URL(string: configuration.serverURL) else {
      throw ScribeError.configuration(
        key: "serverURL",
        reason: "Invalid serverURL in ScribeConfig: \(configuration.serverURL)"
      )
    }
    let client = OpenAICompatibleClient.make(
      serverURL: serverURL, apiKey: configuration.apiKey)
    let harness = AgentHarness(
      client: client,
      model: configuration.agentModel,
      tools: configuration.tools
    )
    return ScribeAgent(harness: harness)
  }

  /// Escape hatch: provide a pre-configured `AgentHarnessProtocol` directly
  /// (e.g. for testing with a custom transport).
  public init(harness: any AgentHarnessProtocol) {
    self.harness = harness
  }

  // MARK: - streamTurn

  /// Execute a single model turn against the supplied conversation history.
  /// Returns a live stream of ``TranscriptEvent`` values plus a `Task` that
  /// resolves with the final messages and outcome.
  public func streamTurn(
    messages: [Components.Schemas.ChatMessage],
    log: Logger,
    temperature: Double = 0,
    maxToolRounds: Int = .max,
    shouldAbortTurn: @escaping @Sendable () -> Bool = { false }
  ) -> TurnStream {
    let (stream, continuation) = AsyncStream<TranscriptEvent>.makeStream()
    var mutable = messages

    let task = Task { [harness] in
      defer { continuation.finish() }
      let clock = ContinuousClock()
      let registry = harness.registry
      log.debug(
        "agent.turn.start",
        metadata: [
          "model": "\(harness.model)", "messages": "\(mutable.count)",
        ])
      var round = 0
      while true {
        round += 1
        if shouldAbortTurn() {
          log.debug("agent.abort", metadata: ["where": "before-http", "round": "\(round)"])
          return TurnResult(messages: mutable, outcome: .interrupted)
        }

        let messagesCountBeforeRound = mutable.count
        let roundStream = harness.runRound(
          messages: mutable,
          logger: log,
          temperature: temperature,
          shouldAbortTurn: shouldAbortTurn
        )

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
          log.debug("agent.abort", metadata: ["where": "post-stream-pre-tools", "round": "\(round)"])
          mutable.removeSubrange(messagesCountBeforeRound..<mutable.endIndex)
          return TurnResult(messages: mutable, outcome: .interrupted)
        }

        switch roundResult.outcome {
        case .completed:
          return TurnResult(messages: mutable, outcome: .completed)

        case .toolCalls(let invocations):
          if round >= maxToolRounds {
            log.notice("event=agent.turn.tool-round-limit max=\(maxToolRounds)")
            mutable.removeSubrange(messagesCountBeforeRound..<mutable.endIndex)
            return TurnResult(messages: mutable, outcome: .toolRoundLimit(rounds: maxToolRounds))
          }

          log.info(
            "agent.tool.round",
            metadata: [
              "round": "\(round)", "tool_count": "\(invocations.count)",
              "tools": "\(invocations.map(\.name).joined(separator: ","))",
            ])
          continuation.yield(.toolRoundHeader(round: round, toolNames: invocations.map(\.name)))

          for inv in invocations {
            if shouldAbortTurn() {
              log.notice(
                "agent.abort",
                metadata: [
                  "where": "pre-tool", "tool": "\(inv.name)", "round": "\(round)",
                ])
              mutable.removeSubrange(messagesCountBeforeRound..<mutable.endIndex)
              return TurnResult(messages: mutable, outcome: .interrupted)
            }
            let toolStarted = clock.now
            let jsonOutput: String
            do {
              jsonOutput = try await registry.run(
                name: inv.name, arguments: inv.arguments, abortVia: shouldAbortTurn)
            } catch is AgentTurnInterruptedError {
              mutable.removeSubrange(messagesCountBeforeRound..<mutable.endIndex)
              return TurnResult(messages: mutable, outcome: .interrupted)
            } catch let ScribeError.toolUnknown(name) {
              log.warning("agent.tool.unknown", metadata: ["tool": "\(name)", "round": "\(round)"])
              jsonOutput = ToolRegistry.jsonError("unknown tool \(name)")
            }
            let elapsedMs = Int(toolStarted.duration(to: clock.now) / .milliseconds(1))
            log.debug(
              "agent.tool.invoke",
              metadata: [
                "round": "\(round)", "tool": "\(inv.name)",
                "args_chars": "\(inv.arguments.count)", "output_chars": "\(jsonOutput.count)",
                "elapsed_ms": "\(elapsedMs)",
              ])
            continuation.yield(.toolInvocation(name: inv.name, arguments: inv.arguments, output: jsonOutput))
            continuation.yield(.blankLine)
            mutable.append(
              Components.Schemas.ChatMessage(
                role: .tool, content: jsonOutput, name: nil, toolCalls: nil, toolCallId: inv.id))
          }
        }
      }
    }

    return TurnStream(events: stream, result: task)
  }
}
