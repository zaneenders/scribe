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


  /// An empty log has no boundaries.
  @Test func emptyLogHasNoBoundaries() {
    let messages: [ScribeMessage] = []
    #expect(messages.safeForkBoundaries() == [])
  }

  /// Plain chat (no tools): every index from 1 through count is safe.
  @Test func plainChatBoundariesIncludeEveryIndex() {
    let messages: [ScribeMessage] = [
      sys(), user("hi"), asst("hello"), user("again"), asst("yo"),
    ]
    #expect(messages.safeForkBoundaries() == [1, 2, 3, 4, 5])
  }

  /// Inside a tool round the cut is unsafe — the assistant's open `tool_calls`
  /// have no matching `tool` results yet.
  @Test func boundaryExcludedBetweenAssistantAndToolResult() {
    let messages: [ScribeMessage] = [
      sys(),
      user("q"),
      asst("", toolCalls: [call("c1")]),
      tool(id: "c1", "ok"),
      asst("done"),
    ]
    // Boundary 3 (between asst+toolcall and tool result) must be excluded.
    #expect(messages.safeForkBoundaries() == [1, 2, 4, 5])
  }

  /// Parallel tool calls close only when *all* matching results arrive.
  @Test func parallelToolCallsRequireAllResults() {
    let messages: [ScribeMessage] = [
      sys(),
      user("q"),
      asst("", toolCalls: [call("c1"), call("c2")]),
      tool(id: "c1", "ok1"),
      tool(id: "c2", "ok2"),
      asst("done"),
    ]
    // After the 1st tool result (index 3) one call is still open → 4 unsafe.
    // After the 2nd (index 4) all closed → 5 safe.
    #expect(messages.safeForkBoundaries() == [1, 2, 5, 6])
  }

  /// Successive tool rounds: the boundary appears after each round closes
  /// and after every final assistant message.
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
    // Indices: 0=sys 1=user 2=asst+c1 3=tool 4=asst+c2 5=tool 6=asst
    // Cuts safe after sys(1), user(2), tool(4), tool(6), asst(7).
    #expect(messages.safeForkBoundaries() == [1, 2, 4, 6, 7])
  }

  /// A log that ends inside an unresolved tool round (interrupted/limit) is
  /// itself not in a closed state — `count` is *not* a safe boundary.
  @Test func unresolvedToolCallExcludesTrailingBoundary() {
    let messages: [ScribeMessage] = [
      sys(),
      user("q"),
      asst("", toolCalls: [call("c1")]),
    ]
    #expect(messages.safeForkBoundaries() == [1, 2])
  }

  /// Zero is never a boundary (a cut that keeps nothing is not useful).
  @Test func zeroIsNeverABoundary() {
    let messages: [ScribeMessage] = [sys(), user("x"), asst("y")]
    #expect(!messages.safeForkBoundaries().contains(0))
  }
}
