public struct AgentRunOptions: Sendable {
  /// Per-run sampling temperature override. When nil, the active profile's
  /// configured temperature is used.
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
