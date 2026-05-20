import Foundation
import ScribeLLM

// MARK: - TurnStream

/// A live stream of ``AgentEvent`` values plus a deferred result that
/// resolves when the turn completes (success, interruption, or error).
///
/// Iterate `events` to react to streaming progress; await `result` for the
/// final messages and outcome.
public struct TurnStream: Sendable {
  /// Yields events as the turn progresses (text deltas, tool calls, usage,
  /// errors, etc.). The stream finishes before or concurrently with `result`.
  public let events: AsyncStream<AgentEvent>

  /// Await this `Task` to obtain the final messages and outcome.
  public let result: Task<TurnResult, Error>

  public init(events: AsyncStream<AgentEvent>, result: Task<TurnResult, Error>) {
    self.events = events
    self.result = result
  }
}

// MARK: - TurnResult

/// The final state after a model turn completes.
public struct TurnResult: Sendable {
  /// The full conversation history after the turn, including any assistant
  /// and tool messages appended during execution.
  public let messages: [ScribeMessage]

  /// How the turn ended.
  public let outcome: TurnOutcome

  public init(
    messages: [ScribeMessage],
    outcome: TurnOutcome
  ) {
    self.messages = messages
    self.outcome = outcome
  }
}
