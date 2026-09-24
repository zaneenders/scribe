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
  public var serviceTier: String?
  public var maxTokens: Int?
  public var sendsOpenCodeHeader: Bool
  public var temperature: Double?
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
    serviceTier: String? = nil,
    maxTokens: Int? = nil,
    sendsOpenCodeHeader: Bool = false,
    temperature: Double? = nil,
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
    self.serviceTier = serviceTier
    self.maxTokens = maxTokens
    self.sendsOpenCodeHeader = sendsOpenCodeHeader
    self.temperature = temperature
    self.maxRetries = maxRetries
  }

  public func withReasoningEffort(_ reasoningEffort: String?) -> ScribeConfig {
    withOverrides(reasoningEffort: reasoningEffort, serviceTier: serviceTier)
  }

  public func withServiceTier(_ serviceTier: String?) -> ScribeConfig {
    withOverrides(reasoningEffort: reasoningEffort, serviceTier: serviceTier)
  }

  private func withOverrides(reasoningEffort: String?, serviceTier: String?) -> ScribeConfig {
    ScribeConfig(
      agentModel: agentModel,
      contextWindow: contextWindow,
      contextWindowThreshold: contextWindowThreshold,
      serverURL: serverURL,
      apiKey: apiKey,
      apiType: apiType,
      tools: tools,
      workingDirectory: workingDirectory,
      reasoningEnabled: reasoningEnabled,
      reasoningEffort: reasoningEffort,
      serviceTier: serviceTier,
      maxTokens: maxTokens,
      sendsOpenCodeHeader: sendsOpenCodeHeader,
      temperature: temperature,
      maxRetries: maxRetries
    )
  }
}
