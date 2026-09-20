import Foundation
import ScribeCore

/// Single mapper from harness-level `AgentEvent` and `TurnOutcome` values to
/// the transport-neutral `ScribeSessionEvent` contract. The local service and
/// any future adapter share this mapping so streamed reduction sees one event
/// vocabulary.
public enum ScribeAgentEventMapper {

  /// Maps one harness event. Returns `nil` for events with no session-level
  /// meaning (ignored by the shared reducer).
  public static func map(_ event: AgentEvent) -> ScribeSessionEvent? {
    switch event {
    case .output(.sectionStarted(let section, _)):
      return .sectionStarted(map(section))
    case .output(.text(let section, let text)):
      return .sectionTextAppended(map(section), text: text)
    case .output(.finalized):
      return nil
    case .output(.empty):
      return .emptyOutput
    case .tool(.invocation):
      return nil
    case .tool(.warning(let warning)):
      return .warning(warning)
    case .lifecycle(.usage(let usage, let rate)):
      return .usage(ScribeUsageSnapshot(usage, tokensPerSecond: rate))
    case .lifecycle(.error(let error)):
      return .error(error.localizedDescription)
    case .lifecycle(.interrupted):
      return .interrupted
    case .lifecycle(.recovered(let reason)):
      return .recovered(reason: reason)
    case .lifecycle(.retrying(let attempt, let maxRetries, let delay, let reason)):
      return .retrying(
        attempt: attempt,
        maxAttempts: maxRetries,
        delaySeconds: seconds(from: delay),
        reason: reason)
    case .boundary(.toolExecutionStart(let name, let arguments)):
      return .toolInvocationStarted(name: name, arguments: arguments)
    case .boundary(.toolExecutionEnd(let name, let output)):
      return .toolInvocationCompleted(name: name, output: output)
    case .boundary(.turnStart(let round)):
      return .toolRoundStarted(round: round)
    case .boundary(.agentStart), .boundary(.agentEnd), .boundary(.turnEnd),
      .boundary(.messageStart), .boundary(.messageEnd):
      return nil
    }
  }

  /// Maps a harness turn outcome to the Codable contract value.
  public static func map(_ outcome: TurnOutcome) -> ScribeTurnOutcome {
    switch outcome {
    case .completed:
      return .completed
    case .incomplete(let reason):
      return .incomplete(reason: reason)
    case .interrupted:
      return .interrupted
    case .toolRoundLimit(let rounds):
      return .toolRoundLimit(rounds: rounds)
    case .error(let message):
      return .error(message)
    }
  }

  /// Display-safe terminal failure message for an error thrown while running
  /// a turn.
  public static func failureMessage(for error: any Error) -> String {
    if let localized = error as? any LocalizedError, let message = localized.errorDescription {
      return message
    }
    return error.localizedDescription
  }

  private static func map(_ section: AssistantStreamSection) -> ScribeStreamSection {
    switch section {
    case .reasoning: return .reasoning
    case .answer: return .answer
    }
  }

  private static func seconds(from duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
  }
}
