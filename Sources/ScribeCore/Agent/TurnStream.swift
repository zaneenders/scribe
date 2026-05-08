import Foundation
import ScribeLLM

// MARK: - RoundStream

/// A live stream of ``TranscriptEvent`` values from a single harness round,
/// plus a deferred result that resolves when the round completes.
public struct RoundStream: Sendable {
  /// Yields events as the LLM response streams in (text deltas, usage, etc.).
  public let events: AsyncStream<TranscriptEvent>

  /// Await this `Task` for the round outcome and updated messages.
  public let result: Task<RoundResult, Error>

  public init(events: AsyncStream<TranscriptEvent>, result: Task<RoundResult, Error>) {
    self.events = events
    self.result = result
  }
}

// MARK: - RoundResult

/// The final state after a single harness round.
public struct RoundResult: Sendable {
  /// The conversation messages after this round (with assistant message appended).
  public let messages: [Components.Schemas.ChatMessage]
  /// Whether the round completed or produced tool calls.
  public let outcome: RoundOutcome

  public init(messages: [Components.Schemas.ChatMessage], outcome: RoundOutcome) {
    self.messages = messages
    self.outcome = outcome
  }
}

// MARK: - TurnStream

/// A live stream of ``TranscriptEvent`` values plus a deferred result that
/// resolves when the turn completes (success, interruption, or error).
///
/// Iterate `events` to react to streaming progress; await `result` for the
/// final messages and outcome.
public struct TurnStream: Sendable {
  /// Yields events as the turn progresses (text deltas, tool calls, usage,
  /// errors, etc.). The stream finishes before or concurrently with `result`.
  public let events: AsyncStream<TranscriptEvent>

  /// Await this `Task` to obtain the final messages and outcome.
  public let result: Task<TurnResult, Error>

  public init(events: AsyncStream<TranscriptEvent>, result: Task<TurnResult, Error>) {
    self.events = events
    self.result = result
  }
}

// MARK: - TurnResult

/// The final state after a model turn completes.
public struct TurnResult: Sendable {
  /// The full conversation history after the turn, including any assistant
  /// and tool messages appended during execution.
  public let messages: [Components.Schemas.ChatMessage]

  /// How the turn ended.
  public let outcome: ModelTurnOutcome

  public init(messages: [Components.Schemas.ChatMessage], outcome: ModelTurnOutcome) {
    self.messages = messages
    self.outcome = outcome
  }
}
