import ScribeLLM

struct AgentStateSnapshot: Sendable {
  let model: String
  let messages: [Components.Schemas.ChatMessage]
  let isStreaming: Bool
  let reasoningEnabled: Bool?

  init(
    model: String,
    messages: [Components.Schemas.ChatMessage],
    isStreaming: Bool,
    reasoningEnabled: Bool?
  ) {
    self.model = model
    self.messages = messages
    self.isStreaming = isStreaming
    self.reasoningEnabled = reasoningEnabled
  }
}
