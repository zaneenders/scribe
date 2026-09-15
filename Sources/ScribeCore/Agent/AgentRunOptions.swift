import Foundation

public struct AgentRunOptions: Sendable {
  public var temperature: Double?
  public var maxToolRounds: Int
  public var sessionId: UUID?

  public init(
    temperature: Double? = nil,
    maxToolRounds: Int = .max,
    sessionId: UUID? = nil
  ) {
    self.sessionId = sessionId
    self.temperature = temperature
    self.maxToolRounds = maxToolRounds
  }
}
