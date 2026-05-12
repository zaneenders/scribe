import ScribeLLM

struct AgentStateSnapshot: Sendable {
  let systemPrompt: String
  let model: String
  let messages: [Components.Schemas.ChatMessage]
  let isStreaming: Bool

  init(
    systemPrompt: String,
    model: String,
    messages: [Components.Schemas.ChatMessage],
    isStreaming: Bool
  ) {
    self.systemPrompt = systemPrompt
    self.model = model
    self.messages = messages
    self.isStreaming = isStreaming
  }
}
