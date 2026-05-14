import Foundation
import ScribeLLM

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
  /// and tool messages appended during execution. Public, transport-agnostic
  /// shape — prefer this for new code.
  public let messages: [ScribeMessage]

  /// The same history in the wire-typed OpenAI-compatible representation.
  /// Kept for the in-tree CLI which still threads
  /// `Components.Schemas.ChatMessage` through its persistence layer.
  public let rawMessages: [Components.Schemas.ChatMessage]

  /// How the turn ended.
  public let outcome: TurnOutcome

  public init(
    messages: [ScribeMessage],
    rawMessages: [Components.Schemas.ChatMessage],
    outcome: TurnOutcome
  ) {
    self.messages = messages
    self.rawMessages = rawMessages
    self.outcome = outcome
  }
}
