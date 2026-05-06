import ScribeCore
import ScribeLLM
import Testing

@Suite
struct MessageRopeTests {

  // MARK: - Init

  @Test func empty() {
    let rope = MessageRope()
    #expect(rope.isEmpty)
    #expect(rope.count == 0)
    #expect(rope.first == nil)
    #expect(rope.last == nil)
    #expect(rope.window(from: 0, count: 10).isEmpty)
  }

  @Test func bulkLoadEmpty() {
    let rope = MessageRope([])
    #expect(rope.isEmpty)
    #expect(rope.count == 0)
  }

  @Test func bulkLoadPreservesOrder() {
    let msgs = (0..<100).map { msg(role: .user, content: "msg-\($0)") }
    let rope = MessageRope(msgs)
    #expect(rope.count == 100)
    for i in 0..<100 {
      #expect(rope.window(from: i, count: 1).first?.content == "msg-\(i)")
    }
  }

  // MARK: - Append

  @Test func appendToEmpty() {
    var rope = MessageRope()
    rope.append(msg(role: .system, content: "sys"))
    #expect(rope.count == 1)
    #expect(rope.first?.content == "sys")
  }

  @Test func appendManyRoundTrips() {
    var rope = MessageRope()
    for i in 0..<500 {
      rope.append(msg(role: .user, content: "m\(i)"))
    }
    #expect(rope.count == 500)
    // Spot-check window extraction at various positions.
    #expect(rope.window(from: 0, count: 1).first?.content == "m0")
    #expect(rope.window(from: 250, count: 1).first?.content == "m250")
    #expect(rope.window(from: 499, count: 1).first?.content == "m499")
  }

  @Test func appendAfterBulkLoad() {
    let initial = (0..<50).map { msg(role: .user, content: "pre-\($0)") }
    var rope = MessageRope(initial)
    for i in 0..<50 {
      rope.append(msg(role: .assistant, content: "post-\(i)"))
    }
    #expect(rope.count == 100)
    #expect(rope.window(from: 0, count: 1).first?.content == "pre-0")
    #expect(rope.window(from: 49, count: 1).first?.content == "pre-49")
    #expect(rope.window(from: 50, count: 1).first?.content == "post-0")
    #expect(rope.window(from: 99, count: 1).first?.content == "post-49")
  }

  // MARK: - first / last

  @Test func firstAndLast() {
    var rope = MessageRope()
    rope.append(msg(role: .system, content: "first"))
    rope.append(msg(role: .user, content: "middle"))
    rope.append(msg(role: .assistant, content: "last"))
    #expect(rope.first?.content == "first")
    #expect(rope.last?.content == "last")
  }

  // MARK: - Window

  @Test func windowFromStart() {
    let msgs = (0..<100).map { msg(role: .user, content: "msg-\($0)") }
    let rope = MessageRope(msgs)
    let slice = rope.window(from: 0, count: 10)
    #expect(slice.count == 10)
    #expect(slice.first?.content == "msg-0")
    #expect(slice.last?.content == "msg-9")
  }

  @Test func windowFromMiddle() {
    let msgs = (0..<100).map { msg(role: .user, content: "msg-\($0)") }
    let rope = MessageRope(msgs)
    let slice = rope.window(from: 40, count: 20)
    #expect(slice.count == 20)
    #expect(slice.first?.content == "msg-40")
    #expect(slice.last?.content == "msg-59")
  }

  @Test func windowNearEndClamps() {
    let msgs = (0..<100).map { msg(role: .user, content: "msg-\($0)") }
    let rope = MessageRope(msgs)
    let slice = rope.window(from: 90, count: 20)
    #expect(slice.count == 10)
    #expect(slice.first?.content == "msg-90")
    #expect(slice.last?.content == "msg-99")
  }

  @Test func windowSimulatedViewportBottom() {
    // Bottom of conversation: 24 viewport + 5 above buffer = 29
    var rope = MessageRope()
    for i in 0..<200 {
      rope.append(msg(role: .user, content: "m\(i)"))
    }
    let viewportMessages = 24
    let bufferAbove = 5
    let total = viewportMessages + bufferAbove  // 29
    let start = max(0, rope.count - total)
    let slice = rope.window(from: start, count: total)
    #expect(slice.count == total)
    #expect(slice.first?.content == "m\(200 - total)")
    #expect(slice.last?.content == "m199")
  }

  @Test func windowSimulatedViewportMiddle() {
    // Middle: 5 above + 24 viewport + 5 below = 34
    var rope = MessageRope()
    for i in 0..<200 {
      rope.append(msg(role: .user, content: "m\(i)"))
    }
    let viewportMessages = 24
    let buffer = 5
    let total = buffer + viewportMessages + buffer  // 34
    let scrollPos = 100
    let start = max(0, scrollPos - buffer)
    let slice = rope.window(from: start, count: total)
    #expect(slice.count == total)
    #expect(slice.first?.content == "m\(scrollPos - buffer)")
  }

  @Test func windowSimulatedViewportTop() {
    // Top: 24 viewport + 5 below = 29
    var rope = MessageRope()
    for i in 0..<200 {
      rope.append(msg(role: .user, content: "m\(i)"))
    }
    let viewportMessages = 24
    let bufferBelow = 5
    let total = viewportMessages + bufferBelow  // 29
    let slice = rope.window(from: 0, count: total)
    #expect(slice.count == total)
    #expect(slice.first?.content == "m0")
    #expect(slice.last?.content == "m\(total - 1)")
  }

  // MARK: - Truncate

  @Test func truncateShrinksCount() {
    var rope = MessageRope()
    for i in 0..<100 {
      rope.append(msg(role: .user, content: "m\(i)"))
    }
    rope.truncate(to: 50)
    #expect(rope.count == 50)
    #expect(rope.last?.content == "m49")
  }

  @Test func truncateToZero() {
    var rope = MessageRope()
    rope.append(msg(role: .system, content: "sys"))
    rope.truncate(to: 0)
    #expect(rope.isEmpty)
    #expect(rope.count == 0)
  }

  @Test func truncateAfterWindowStillConsistent() {
    var rope = MessageRope()
    for i in 0..<200 {
      rope.append(msg(role: .user, content: "m\(i)"))
    }
    // Take a window, then truncate the original.
    let win = rope.window(from: 50, count: 30)
    rope.truncate(to: 80)
    #expect(rope.count == 80)
    #expect(rope.last?.content == "m79")
    // Window snapshot unaffected.
    #expect(win.count == 30)
    #expect(win.first?.content == "m50")
  }

  // MARK: - forEach

  @Test func forEachWalksAll() {
    let msgs = (0..<128).map { msg(role: .user, content: "m\($0)") }
    let rope = MessageRope(msgs)
    var seen: [String] = []
    rope.forEach { seen.append($0.content ?? "") }
    #expect(seen.count == 128)
    #expect(seen.first == "m0")
    #expect(seen.last == "m127")
  }

  // MARK: - Realistic chat shape

  @Test func realisticChatSequence() {
    var rope = MessageRope()
    rope.append(msg(role: .system, content: "You are a helpful assistant."))

    for turn in 0..<20 {
      rope.append(msg(role: .user, content: "Question \(turn)?"))
      rope.append(msg(role: .assistant, content: "Answer \(turn)."))
      if turn % 3 == 0 {
        rope.append(
          msg(
            role: .assistant, content: "",
            toolCalls: [
              .init(id: "t\(turn)", _type: "function", function: .init(name: "shell", arguments: "{}"))
            ]))
        rope.append(msg(role: .tool, content: "output \(turn)", toolCallId: "t\(turn)"))
        rope.append(msg(role: .assistant, content: "After tool \(turn)."))
      }
    }

    #expect(rope.first?.role == .system)
    #expect(rope.count > 60)

    let win = rope.window(from: max(0, rope.count - 34), count: 34)
    #expect(!win.isEmpty)
    #expect(win.count <= 34)
  }

  // MARK: - Role round-trip

  @Test func rolesSurviveRoundTrip() {
    var rope = MessageRope()
    rope.append(msg(role: .system, content: "sys"))
    rope.append(msg(role: .user, content: "u"))
    rope.append(msg(role: .assistant, content: "a"))
    rope.append(msg(role: .tool, content: "t", toolCallId: "call_1"))

    #expect(rope.window(from: 0, count: 1).first?.role == .system)
    #expect(rope.window(from: 1, count: 1).first?.role == .user)
    #expect(rope.window(from: 2, count: 1).first?.role == .assistant)
    #expect(rope.window(from: 3, count: 1).first?.role == .tool)
    #expect(rope.window(from: 3, count: 1).first?.toolCallId == "call_1")
  }

  // MARK: - Helpers

  private func msg(
    role: Components.Schemas.ChatMessage.RolePayload,
    content: String,
    toolCalls: [Components.Schemas.AssistantToolCall]? = nil,
    toolCallId: String? = nil
  ) -> Components.Schemas.ChatMessage {
    .init(
      role: role,
      content: content,
      name: nil,
      toolCalls: toolCalls,
      toolCallId: toolCallId,
      reasoningContent: nil
    )
  }
}
