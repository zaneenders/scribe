import Foundation
import ScribeCore
import ScribeLLM
import Testing

@Suite
struct ScribeMessageTests {

  // MARK: - Codable round-trip

  @Test func roundTripsUserMessage() throws {
    let msg = ScribeMessage(role: .user, content: "hello world")
    let data = try JSONEncoder().encode(msg)
    let decoded = try JSONDecoder().decode(ScribeMessage.self, from: data)
    #expect(decoded == msg)
  }

  @Test func roundTripsAssistantWithToolCalls() throws {
    let msg = ScribeMessage(
      role: .assistant,
      content: "",
      toolCalls: [
        ScribeToolCall(id: "c1", name: "shell", arguments: #"{"cmd":"ls"}"#),
        ScribeToolCall(id: "c2", name: "read_file", arguments: #"{"path":"a.txt"}"#),
      ],
      reasoning: "step by step"
    )
    let data = try JSONEncoder().encode(msg)
    let json = String(data: data, encoding: .utf8) ?? ""
    // Wire keys must remain snake_case (matches the OpenAI shape on disk).
    #expect(json.contains("\"tool_calls\""))
    #expect(json.contains("\"reasoning_content\""))
    #expect(json.contains("\"function\""))
    let decoded = try JSONDecoder().decode(ScribeMessage.self, from: data)
    #expect(decoded == msg)
  }

  @Test func roundTripsToolMessage() throws {
    let msg = ScribeMessage(
      role: .tool,
      content: #"{"ok":true}"#,
      toolCallId: "c1"
    )
    let data = try JSONEncoder().encode(msg)
    let json = String(data: data, encoding: .utf8) ?? ""
    #expect(json.contains("\"tool_call_id\""))
    let decoded = try JSONDecoder().decode(ScribeMessage.self, from: data)
    #expect(decoded == msg)
  }

  // MARK: - Decoding legacy / wire format

  /// Sessions saved before ``ScribeMessage`` existed encoded
  /// `Components.Schemas.ChatMessage` directly; the on-disk shape uses
  /// snake_case keys, possibly-null `content`, and nested
  /// `{id, type, function:{name, arguments}}` tool calls. Decoding that
  /// shape must continue to work.
  @Test func decodesOpenAIWireFormat() throws {
    let json = #"""
      {
        "role": "assistant",
        "content": null,
        "tool_calls": [
          { "id": "c1", "type": "function", "function": { "name": "shell", "arguments": "{}" } }
        ],
        "reasoning_content": "let me think"
      }
      """#
    let decoded = try JSONDecoder().decode(ScribeMessage.self, from: Data(json.utf8))
    #expect(decoded.role == .assistant)
    #expect(decoded.content == "")  // null collapses to empty
    #expect(decoded.toolCalls?.count == 1)
    #expect(decoded.toolCalls?.first?.id == "c1")
    #expect(decoded.toolCalls?.first?.name == "shell")
    #expect(decoded.toolCalls?.first?.arguments == "{}")
    #expect(decoded.reasoning == "let me think")
  }
}
