import Foundation
import ScribeLLM

public struct TurnStream: Sendable {

  public let events: AsyncStream<AgentEvent>

  public let result: Task<TurnResult, Error>

  public init(events: AsyncStream<AgentEvent>, result: Task<TurnResult, Error>) {
    self.events = events
    self.result = result
  }
}

public struct TurnResult: Sendable {

  public let newMessages: [ScribeMessage]

  public let outcome: TurnOutcome

  public init(
    newMessages: [ScribeMessage],
    outcome: TurnOutcome
  ) {
    self.newMessages = newMessages
    self.outcome = outcome
  }
}
