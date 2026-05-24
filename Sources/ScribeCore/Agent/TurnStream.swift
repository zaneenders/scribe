import Foundation
import ScribeLLM

// MARK: - TurnStream

/// A live stream of ``AgentEvent`` values plus a deferred result that
/// resolves when the turn completes (success, interruption, or error).
///
/// Iterate `events` to react to streaming progress; await `result` for the
/// new messages and outcome.
public struct TurnStream: Sendable {
  /// Yields events as the turn progresses (text deltas, tool calls, usage,
  /// errors, etc.). The stream finishes before or concurrently with `result`.
  public let events: AsyncStream<AgentEvent>

  /// Await this `Task` to obtain the turn's new messages and outcome.
  public let result: Task<TurnResult, Error>

  public init(events: AsyncStream<AgentEvent>, result: Task<TurnResult, Error>) {
    self.events = events
    self.result = result
  }
}

// MARK: - TurnResult

/// The outcome of a model turn.
///
/// `newMessages` is the diff produced by the turn — the prompt messages
/// plus everything generated during the agent loop (assistant deltas,
/// tool invocations, tool results). The caller is responsible for
/// folding these back into whatever store it owns (typically a
/// ``SessionDocument``).
public struct TurnResult: Sendable {
  /// Messages produced by this turn: the prompt(s) plus all assistant /
  /// tool messages generated during the loop. Excludes the pre-turn
  /// history the caller supplied.
  public let newMessages: [ScribeMessage]

  /// How the turn ended.
  public let outcome: TurnOutcome

  public init(
    newMessages: [ScribeMessage],
    outcome: TurnOutcome
  ) {
    self.newMessages = newMessages
    self.outcome = outcome
  }
}
