public struct AgentRunOptions: Sendable {
  public var temperature: Double?
  public var maxToolRounds: Int

  public init(
    temperature: Double? = nil,
    maxToolRounds: Int = .max
  ) {
    self.temperature = temperature
    self.maxToolRounds = maxToolRounds
  }
}
