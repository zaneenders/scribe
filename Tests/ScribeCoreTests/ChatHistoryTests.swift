import Foundation
import ScribeCore
import ScribeLLM
import Testing

@Suite
struct ChatHistoryTests {
  @Test func returnsLatestAssistantContent() {
    let messages: [Components.Schemas.ChatMessage] = [
      .init(role: .user, content: "hi", name: nil, toolCalls: nil, toolCallId: nil),
      .init(role: .assistant, content: "first", name: nil, toolCalls: nil, toolCallId: nil),
      .init(role: .assistant, content: "last", name: nil, toolCalls: nil, toolCallId: nil),
    ]
    #expect(ChatHistory.lastAssistantText(from: messages) == "last")
  }

  @Test func returnsNilWithoutAssistant() {
    let messages: [Components.Schemas.ChatMessage] = [
      .init(role: .user, content: "only user", name: nil, toolCalls: nil, toolCallId: nil)
    ]
    #expect(ChatHistory.lastAssistantText(from: messages) == nil)
  }
}
