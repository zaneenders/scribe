// MARK: - AgentConfig

/// Agent configuration that controls LLM model selection, context window,
/// and the OpenAI-compatible API endpoint.
///
/// `ScribeAgent` can construct its HTTP client from this config alone,
/// so callers no longer need to create a `Client` themselves.
public struct AgentConfig: Sendable {
  public var agentModel: String
  public var contextWindow: Int
  public var contextWindowThreshold: Double
  /// OpenAI-compatible server base URL (e.g. `"http://localhost:11434"` for Ollama).
  /// The agent appends `/v1/chat/completions` to this.
  public var serverURL: String
  /// Optional bearer token for the API.
  public var bearerToken: String?
  /// Maximum number of tool-call rounds per model turn. When exceeded the turn
  /// returns `.toolRoundLimit` rather than looping forever. Default unlimited.
  public var maxToolRounds: Int
  /// LLM sampling temperature (0.0–2.0). Default 0 for deterministic output.
  public var temperature: Double

  public init(
    agentModel: String,
    contextWindow: Int = 131_072,
    contextWindowThreshold: Double = 0.85,
    serverURL: String = "https://api.openai.com",
    bearerToken: String? = nil,
    maxToolRounds: Int = .max,
    temperature: Double = 0
  ) {
    self.agentModel = agentModel
    self.contextWindow = contextWindow
    self.contextWindowThreshold = contextWindowThreshold
    self.serverURL = serverURL
    self.bearerToken = bearerToken
    self.maxToolRounds = maxToolRounds
    self.temperature = temperature
  }
}
