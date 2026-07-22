public struct ScribeConfig: Sendable {
  public var agentModel: String
  public var contextWindow: Int
  public var contextWindowThreshold: Double

  public var serverURL: String
  public var apiKey: String?
  public var apiType: String?
  public var tools: [any ScribeTool]

  public var workingDirectory: String
  public var reasoningEnabled: Bool?
  public var reasoningEffort: String?
  public var maxTokens: Int?
  /// Retries per provider round on transient networking failures; `nil` uses the
  /// default policy, `0` disables retrying.
  public var maxRetries: Int?
  public init(
    agentModel: String,
    contextWindow: Int,
    contextWindowThreshold: Double,
    serverURL: String,
    apiKey: String? = nil,
    apiType: String? = nil,
    tools: [any ScribeTool] = [],
    workingDirectory: String,
    reasoningEnabled: Bool?,
    reasoningEffort: String? = nil,
    maxTokens: Int? = nil,
    maxRetries: Int? = nil
  ) {
    self.agentModel = agentModel
    self.contextWindow = contextWindow
    self.contextWindowThreshold = contextWindowThreshold
    self.serverURL = serverURL
    self.apiKey = apiKey
    self.apiType = apiType
    self.tools = tools
    self.workingDirectory = workingDirectory
    self.reasoningEnabled = reasoningEnabled
    self.reasoningEffort = reasoningEffort
    self.maxTokens = maxTokens
    self.maxRetries = maxRetries
  }
}
