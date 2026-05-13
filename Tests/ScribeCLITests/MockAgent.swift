import Foundation
import Logging
import ScribeCore
import ScribeLLM

// MARK: - MockAgent

/// Minimal `AgentProtocol` implementation for testing `ChatCoordinator` without
/// a live LLM connection.
///
/// The mock stores incoming user messages and returns a canned `TurnStream`
/// with configurable events and outcome.
actor MockAgent: AgentProtocol {

  private var _messages: [Components.Schemas.ChatMessage]
  private let makeTurnStream: @Sendable () -> TurnStream

  /// Create a mock agent that returns a default "Mock response" answer for every turn.
  /// - Parameters:
  ///   - messages: Initial transcript messages.
  static func makeDefault(messages: [Components.Schemas.ChatMessage] = []) -> MockAgent {
    self.init(
      messages: messages,
      makeTurnStream: {
        let (stream, cont) = AsyncStream<TranscriptEvent>.makeStream()
        cont.yield(.enterAssistantSection(.answer, previous: nil))
        cont.yield(.appendAssistantText(.answer, text: "Mock response"))
        cont.yield(.finalizeAssistantStream)
        cont.yield(.turnComplete(referenceMessages: []))
        cont.finish()
        let result = Task<TurnResult, Error> {
          TurnResult(messages: [], outcome: .completed)
        }
        return TurnStream(events: stream, result: result)
      }
    )
  }

  /// Create a mock agent with full control over the turn output.
  /// - Parameters:
  ///   - messages: Initial transcript messages.
  ///   - makeTurnStream: Closure that produces a `TurnStream` for each `prompt()` call.
  init(
    messages: [Components.Schemas.ChatMessage] = [],
    makeTurnStream: @escaping @Sendable () -> TurnStream
  ) {
    self._messages = messages
    self.makeTurnStream = makeTurnStream
  }

  nonisolated var messages: [Components.Schemas.ChatMessage] {
    get async { await _messages }
  }

  func messages(since start: Int) async -> [Components.Schemas.ChatMessage] {
    guard start < _messages.count else { return [] }
    let clamped = max(start, 0)
    return Array(_messages[clamped...])
  }

  func prompt(
    _ input: String,
    options: AgentRunOptions,
    log: Logger
  ) async -> TurnStream {
    _messages.append(.init(role: .user, content: input))
    return makeTurnStream()
  }

  nonisolated func abort() {
    // No-op: mock doesn't run long operations.
  }
}
