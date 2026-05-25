

public struct ScribeConfig: Sendable {
  public var agentModel: String
  public var contextWindow: Int
  public var contextWindowThreshold: Double

  public var serverURL: String
  public var apiKey: String?
  public var tools: [any ScribeTool]

  public var workingDirectory: String
  public var reasoningEnabled: Bool?
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
