public struct AgentRunOptions: Sendable {
  public var temperature: Double
  public var maxToolRounds: Int

  public init(
    temperature: Double = 0,
    maxToolRounds: Int = .max
  ) {
    self.temperature = temperature
    self.maxToolRounds = maxToolRounds
  }
}
