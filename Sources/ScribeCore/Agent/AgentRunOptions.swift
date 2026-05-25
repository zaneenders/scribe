public struct AgentRunOptions: Sendable {
  public var temperature: Double
  public var maxToolRounds: Int
  public var hooks: AgentLoopHooks

  public init(
    temperature: Double = 0,
    maxToolRounds: Int = .max,
    hooks: AgentLoopHooks = .default
  ) {
    self.temperature = temperature
    self.maxToolRounds = maxToolRounds
    self.hooks = hooks
  }
}
