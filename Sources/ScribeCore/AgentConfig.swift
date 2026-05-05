// MARK: - AgentConfig

/// Agent configuration that controls LLM model selection and context window.
/// Callers provide this directly; there is no filesystem loading in
/// this target — CLI-side code owns config-file parsing and HTTP client
/// creation.
public struct AgentConfig: Sendable {
  public var agentModel: String
  public var contextWindow: Int
  public var contextWindowThreshold: Double

  public init(
    agentModel: String,
    contextWindow: Int,
    contextWindowThreshold: Double
  ) {
    self.agentModel = agentModel
    self.contextWindow = contextWindow
    self.contextWindowThreshold = contextWindowThreshold
  }
}
