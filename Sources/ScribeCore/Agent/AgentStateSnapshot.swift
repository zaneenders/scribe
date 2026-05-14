import ScribeLLM

struct AgentStateSnapshot: Sendable {
  let model: String
  let messages: [Components.Schemas.ChatMessage]
  let isStreaming: Bool

  init(
    model: String,
    messages: [Components.Schemas.ChatMessage],
    isStreaming: Bool
  ) {
    self.model = model
    self.messages = messages
    self.isStreaming = isStreaming
  }
}
