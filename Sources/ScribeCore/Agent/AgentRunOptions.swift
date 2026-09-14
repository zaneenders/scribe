import Foundation

public struct AgentRunOptions: Sendable {
  /// Per-run sampling temperature override. When nil, the active profile's
  /// configured temperature is used.
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
