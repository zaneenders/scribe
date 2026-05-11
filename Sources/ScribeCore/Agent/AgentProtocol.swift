import Foundation
import Logging
import ScribeLLM

// MARK: - AgentProtocol

/// Protocol abstracting the agent turn-loop so `ChatCoordinator` can be tested
/// with a mock instead of requiring a live LLM connection.
///
/// Conforming types must be `actor` (or otherwise `Sendable`) because the
/// coordinator accesses agent state from its own actor context.
public protocol AgentProtocol: Sendable {
  /// All messages in the conversation transcript.
  var messages: [Components.Schemas.ChatMessage] { get async }

  /// Messages appended since the given index (used for incremental persistence).
  func messages(since start: Int) async -> [Components.Schemas.ChatMessage]

  /// Run a turn: append the user message, execute the agent loop, and return
  /// a stream of live transcript events.
  func prompt(
    _ input: String,
    options: AgentRunOptions,
    log: Logger
  ) async -> TurnStream
}

// MARK: - AgentFactory

/// Creates an agent given the initial messages (system prompt + resume snapshot).
/// Used by `ChatCoordinator` to construct the agent after determining whether
/// to resume or start fresh.
public typealias AgentFactory = @Sendable (
  _ initialMessages: [Components.Schemas.ChatMessage]
) async throws -> any AgentProtocol
