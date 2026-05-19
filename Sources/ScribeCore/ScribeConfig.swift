// MARK: - ScribeConfig

/// Agent configuration that controls LLM model selection, context window,
/// the OpenAI-compatible API endpoint, and the tool set available to the agent.
///
/// `ScribeAgent` can construct its HTTP client from this config alone,
/// so callers no longer need to create a `Client` themselves.
public struct ScribeConfig: Sendable {
  public var agentModel: String
  public var contextWindow: Int
  public var contextWindowThreshold: Double
  /// OpenAI-compatible server base URL (e.g. `"http://localhost:11434"` for Ollama).
  /// The agent appends `/v1/chat/completions` to this.
  public var serverURL: String
  public var apiKey: String?
  public var tools: [any ScribeTool]
  /// Absolute working directory for tool path resolution.
  public var workingDirectory: String
  public var reasoningEnabled: Bool?  // May need to set this to null for some providers
  public init(
    agentModel: String,
    contextWindow: Int,
    contextWindowThreshold: Double,
    serverURL: String,
    apiKey: String? = nil,
    tools: [any ScribeTool] = [],
    workingDirectory: String,
    reasoningEnabled: Bool?
  ) {
    self.agentModel = agentModel
    self.contextWindow = contextWindow
    self.contextWindowThreshold = contextWindowThreshold
    self.serverURL = serverURL
    self.apiKey = apiKey
    self.tools = tools
    self.workingDirectory = workingDirectory
    self.reasoningEnabled = reasoningEnabled
  }
}
