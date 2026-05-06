import Foundation
import ScribeCore
import ScribeLLM
import Testing

/// Tests for `AgentHarness.buildPayload` covering the `maxContextMessages`
/// message-limiting logic.
@Suite
struct AgentHarnessTests {

  // MARK: - Helpers

  private func msg(
    role: Components.Schemas.ChatMessage.RolePayload,
    content: String
  ) -> Components.Schemas.ChatMessage {
    .init(role: role, content: content, name: nil, toolCalls: nil, toolCallId: nil, reasoningContent: nil)
  }

  private func rope(_ msgs: [Components.Schemas.ChatMessage]) -> MessageRope {
    MessageRope(msgs)
  }

  // MARK: - No limit

  @Test func nilMaxContextMessagesReturnsAllMessages() {
    let messages = rope([
      msg(role: .system, content: "sys"),
      msg(role: .user, content: "u1"),
      msg(role: .assistant, content: "a1"),
    ])
    let payload = AgentHarness.buildPayload(messages: messages, maxContextMessages: nil)
    #expect(payload.count == 3)
    #expect(payload[0].content == "sys")
    #expect(payload[2].content == "a1")
  }

  // MARK: - Under limit

  @Test func underLimitReturnsAllMessages() {
    let messages = rope([
      msg(role: .system, content: "sys"),
      msg(role: .user, content: "u1"),
      msg(role: .assistant, content: "a1"),
    ])
    let payload = AgentHarness.buildPayload(messages: messages, maxContextMessages: 10)
    #expect(payload.count == 3)
  }

  @Test func exactlyAtLimitReturnsAllMessages() {
    let msgs =
      [msg(role: .system, content: "sys")]
      + (0..<4).map { msg(role: .user, content: "u\($0)") }
    let messages = rope(msgs)
    #expect(messages.count == 5)
    let payload = AgentHarness.buildPayload(messages: messages, maxContextMessages: 5)
    #expect(payload.count == 5)
  }

  // MARK: - Over limit

  @Test func overLimitPreservesSystemMessageAndTruncatesOldest() {
    let msgs =
      [msg(role: .system, content: "sys")]
      + (0..<100).map { msg(role: .user, content: "u\($0)") }
    let messages = rope(msgs)
    #expect(messages.count == 101)

    let payload = AgentHarness.buildPayload(messages: messages, maxContextMessages: 10)
    #expect(payload.count == 10)
    // First message must be system.
    #expect(payload.first?.role == Components.Schemas.ChatMessage.RolePayload.system)
    #expect(payload.first?.content == "sys")
    // Last message must be u99.
    #expect(payload.last?.content == "u99")
    // Second message should be u91 (since we keep 9 recent + 1 system).
    #expect(payload[1].content == "u91")
  }

  @Test func overLimitWithToolMessagesPreservesSystemAndRecent() {
    var msgs: [Components.Schemas.ChatMessage] = [msg(role: .system, content: "sys")]
    for i in 0..<50 {
      msgs.append(msg(role: .user, content: "u\(i)"))
      msgs.append(msg(role: .assistant, content: "a\(i)"))
      if i % 5 == 0 {
        msgs.append(
          .init(
            role: .assistant, content: "", name: nil,
            toolCalls: [
              .init(
                id: "t\(i)", _type: "function",
                function: .init(name: "shell", arguments: "{}"))
            ],
            toolCallId: nil, reasoningContent: nil))
        msgs.append(
          .init(
            role: .tool, content: "out\(i)", name: nil,
            toolCalls: nil, toolCallId: "t\(i)", reasoningContent: nil))
        msgs.append(msg(role: .assistant, content: "final\(i)"))
      }
    }
    let messages = rope(msgs)

    let payload = AgentHarness.buildPayload(messages: messages, maxContextMessages: 20)
    #expect(payload.count == 20)
    #expect(payload.first?.role == Components.Schemas.ChatMessage.RolePayload.system)
    // The last message should still be present.
    #expect(payload.last?.content == messages.window(from: messages.count - 1, count: 1).first?.content)
  }

  // MARK: - Edge cases

  @Test func limitOfTwoKeepsOnlySystemAndLastMessage() {
    let msgs: [Components.Schemas.ChatMessage] = [
      msg(role: .system, content: "sys"),
      msg(role: .user, content: "first"),
      msg(role: .assistant, content: "middle"),
      msg(role: .user, content: "last"),
    ]
    let messages = rope(msgs)
    #expect(messages.count == 4)

    let payload = AgentHarness.buildPayload(messages: messages, maxContextMessages: 2)
    #expect(payload.count == 2)
    #expect(payload[0].role == Components.Schemas.ChatMessage.RolePayload.system)
    #expect(payload[0].content == "sys")
    #expect(payload[1].content == "last")
  }

  @Test func limitOfOneKeepsOnlySystemMessage() {
    let messages = rope([
      msg(role: .system, content: "sys"),
      msg(role: .user, content: "u"),
    ])
    let payload = AgentHarness.buildPayload(messages: messages, maxContextMessages: 1)
    #expect(payload.count == 1)
    #expect(payload[0].role == Components.Schemas.ChatMessage.RolePayload.system)
  }

  @Test func emptyRopeReturnsEmpty() {
    let messages = MessageRope()
    let payload = AgentHarness.buildPayload(messages: messages, maxContextMessages: 10)
    #expect(payload.isEmpty)
  }

  @Test func singleSystemMessageWithLimitReturnsIt() {
    let messages = rope([msg(role: .system, content: "sys")])
    let payload = AgentHarness.buildPayload(messages: messages, maxContextMessages: 10)
    #expect(payload.count == 1)
    #expect(payload[0].role == Components.Schemas.ChatMessage.RolePayload.system)
  }
}
