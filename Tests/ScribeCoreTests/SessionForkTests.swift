import Testing

@testable import ScribeCore

@Suite
struct SessionForkTests {

  private func sys(_ text: String = "sys") -> ScribeMessage {
    ScribeMessage(role: .system, content: text)
  }

  private func user(_ text: String) -> ScribeMessage {
    ScribeMessage(role: .user, content: text)
  }

  private func asst(_ text: String, toolCalls: [ScribeToolCall]? = nil) -> ScribeMessage {
    ScribeMessage(role: .assistant, content: text, toolCalls: toolCalls)
  }

  private func tool(id: String, _ text: String) -> ScribeMessage {
    ScribeMessage(role: .tool, content: text, toolCallId: id)
  }

  private func call(_ id: String, name: String = "shell") -> ScribeToolCall {
    ScribeToolCall(id: id, name: name, arguments: "{}")
  }

  @Test func emptyLogHasNoBoundaries() {
    let messages: [ScribeMessage] = []
    #expect(messages.safeForkBoundaries() == [])
  }

  @Test func plainChatBoundariesIncludeEveryIndex() {
    let messages: [ScribeMessage] = [
      sys(), user("hi"), asst("hello"), user("again"), asst("yo"),
    ]
    #expect(messages.safeForkBoundaries() == [1, 2, 3, 4, 5])
  }

  @Test func boundaryExcludedBetweenAssistantAndToolResult() {
    let messages: [ScribeMessage] = [
      sys(),
      user("q"),
      asst("", toolCalls: [call("c1")]),
      tool(id: "c1", "ok"),
      asst("done"),
    ]

    #expect(messages.safeForkBoundaries() == [1, 2, 4, 5])
  }

  @Test func parallelToolCallsRequireAllResults() {
    let messages: [ScribeMessage] = [
      sys(),
      user("q"),
      asst("", toolCalls: [call("c1"), call("c2")]),
      tool(id: "c1", "ok1"),
      tool(id: "c2", "ok2"),
      asst("done"),
    ]

    #expect(messages.safeForkBoundaries() == [1, 2, 5, 6])
  }

  @Test func successiveToolRoundsBoundariesOnlyBetweenRounds() {
    let messages: [ScribeMessage] = [
      sys(),
      user("q"),
      asst("", toolCalls: [call("c1")]),
      tool(id: "c1", "r1"),
      asst("", toolCalls: [call("c2")]),
      tool(id: "c2", "r2"),
      asst("done"),
    ]

    #expect(messages.safeForkBoundaries() == [1, 2, 4, 6, 7])
  }

  @Test func unresolvedToolCallExcludesTrailingBoundary() {
    let messages: [ScribeMessage] = [
      sys(),
      user("q"),
      asst("", toolCalls: [call("c1")]),
    ]
    #expect(messages.safeForkBoundaries() == [1, 2])
  }

  @Test func zeroIsNeverABoundary() {
    let messages: [ScribeMessage] = [sys(), user("x"), asst("y")]
    #expect(!messages.safeForkBoundaries().contains(0))
  }
}
