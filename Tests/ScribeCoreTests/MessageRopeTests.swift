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
      #expect(rope.window(from: i, count: 1).first?.textContent == "msg-\(i)")
    }
  }

  // MARK: - Append

  @Test func appendToEmpty() {
    var rope = MessageRope()
    rope.append(msg(role: .system, content: "sys"))
    #expect(rope.count == 1)
    #expect(rope.first?.textContent == "sys")
  }

  @Test func appendManyRoundTrips() {
    var rope = MessageRope()
    for i in 0..<500 {
      rope.append(msg(role: .user, content: "m\(i)"))
    }
    #expect(rope.count == 500)
    // Spot-check window extraction at various positions.
    #expect(rope.window(from: 0, count: 1).first?.textContent == "m0")
    #expect(rope.window(from: 250, count: 1).first?.textContent == "m250")
    #expect(rope.window(from: 499, count: 1).first?.textContent == "m499")
  }

  @Test func appendAfterBulkLoad() {
    let initial = (0..<50).map { msg(role: .user, content: "pre-\($0)") }
    var rope = MessageRope(initial)
    for i in 0..<50 {
      rope.append(msg(role: .assistant, content: "post-\(i)"))
    }
    #expect(rope.count == 100)
    #expect(rope.window(from: 0, count: 1).first?.textContent == "pre-0")
    #expect(rope.window(from: 49, count: 1).first?.textContent == "pre-49")
    #expect(rope.window(from: 50, count: 1).first?.textContent == "post-0")
    #expect(rope.window(from: 99, count: 1).first?.textContent == "post-49")
  }

  // MARK: - first / last

  @Test func firstAndLast() {
    var rope = MessageRope()
    rope.append(msg(role: .system, content: "first"))
    rope.append(msg(role: .user, content: "middle"))
    rope.append(msg(role: .assistant, content: "last"))
    #expect(rope.first?.textContent == "first")
    #expect(rope.last?.textContent == "last")
  }

  // MARK: - Window

  @Test func windowFromStart() {
    let msgs = (0..<100).map { msg(role: .user, content: "msg-\($0)") }
    let rope = MessageRope(msgs)
    let slice = rope.window(from: 0, count: 10)
    #expect(slice.count == 10)
    #expect(slice.first?.textContent == "msg-0")
    #expect(slice.last?.textContent == "msg-9")
  }

  @Test func windowFromMiddle() {
    let msgs = (0..<100).map { msg(role: .user, content: "msg-\($0)") }
    let rope = MessageRope(msgs)
    let slice = rope.window(from: 40, count: 20)
    #expect(slice.count == 20)
    #expect(slice.first?.textContent == "msg-40")
    #expect(slice.last?.textContent == "msg-59")
  }

  @Test func windowNearEndClamps() {
    let msgs = (0..<100).map { msg(role: .user, content: "msg-\($0)") }
    let rope = MessageRope(msgs)
    let slice = rope.window(from: 90, count: 20)
    #expect(slice.count == 10)
    #expect(slice.first?.textContent == "msg-90")
    #expect(slice.last?.textContent == "msg-99")
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
    #expect(slice.first?.textContent == "m\(200 - total)")
    #expect(slice.last?.textContent == "m199")
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
    #expect(slice.first?.textContent == "m\(scrollPos - buffer)")
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
    #expect(slice.first?.textContent == "m0")
    #expect(slice.last?.textContent == "m\(total - 1)")
  }

  // MARK: - Truncate

  @Test func truncateShrinksCount() {
    var rope = MessageRope()
    for i in 0..<100 {
      rope.append(msg(role: .user, content: "m\(i)"))
    }
    rope.truncate(to: 50)
    #expect(rope.count == 50)
    #expect(rope.last?.textContent == "m49")
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
    #expect(rope.last?.textContent == "m79")
    // Window snapshot unaffected.
    #expect(win.count == 30)
    #expect(win.first?.textContent == "m50")
  }

  // MARK: - forEach

  @Test func forEachWalksAll() {
    let msgs = (0..<128).map { msg(role: .user, content: "m\($0)") }
    let rope = MessageRope(msgs)
    var seen: [String] = []
    rope.forEach { seen.append($0.textContent ?? "") }
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

  // MARK: - Window edge cases

  @Test func windowStartPastEndReturnsEmpty() {
    let rope = MessageRope((0..<10).map { msg(role: .user, content: "m\($0)") })
    let slice = rope.window(from: 10, count: 5)
    #expect(slice.isEmpty)
  }

  @Test func windowStartPastEndOnEmptyRopeReturnsEmpty() {
    let rope = MessageRope()
    let slice = rope.window(from: 0, count: 10)
    #expect(slice.isEmpty)
  }

  @Test func windowNegativeStartReturnsEmpty() {
    let rope = MessageRope((0..<10).map { msg(role: .user, content: "m\($0)") })
    let slice = rope.window(from: -1, count: 5)
    #expect(slice.isEmpty)
  }

  @Test func windowZeroCountReturnsEmpty() {
    let rope = MessageRope((0..<10).map { msg(role: .user, content: "m\($0)") })
    let slice = rope.window(from: 3, count: 0)
    #expect(slice.isEmpty)
  }

  @Test func windowFromExactStart() {
    let rope = MessageRope((0..<50).map { msg(role: .user, content: "m\($0)") })
    let slice = rope.window(from: 0, count: 50)
    #expect(slice.count == 50)
    #expect(slice.first?.textContent == "m0")
    #expect(slice.last?.textContent == "m49")
  }

  // MARK: - Truncate edge cases

  @Test func truncateToSameCountIsNoOp() {
    var rope = MessageRope((0..<50).map { msg(role: .user, content: "m\($0)") })
    rope.truncate(to: 50)
    #expect(rope.count == 50)
    #expect(rope.last?.textContent == "m49")
  }

  @Test func truncateToGreaterCountIsNoOp() {
    var rope = MessageRope((0..<10).map { msg(role: .user, content: "m\($0)") })
    rope.truncate(to: 100)
    #expect(rope.count == 10)
    #expect(rope.last?.textContent == "m9")
  }

  @Test func truncateFromOneToZeroThenAppend() {
    var rope = MessageRope()
    rope.append(msg(role: .user, content: "only"))
    rope.truncate(to: 0)
    #expect(rope.isEmpty)
    rope.append(msg(role: .assistant, content: "after"))
    #expect(rope.count == 1)
    #expect(rope.first?.textContent == "after")
  }

  // MARK: - Chained operations

  @Test func appendTruncateWindowRoundTrip() {
    var rope = MessageRope()
    // Build up
    for i in 0..<200 {
      rope.append(msg(role: .user, content: "m\(i)"))
    }
    #expect(rope.count == 200)
    // Truncate
    rope.truncate(to: 150)
    #expect(rope.count == 150)
    #expect(rope.last?.textContent == "m149")
    // Append more
    for i in 0..<50 {
      rope.append(msg(role: .assistant, content: "a\(i)"))
    }
    #expect(rope.count == 200)
    #expect(rope.last?.textContent == "a49")
    // Window still works
    let slice = rope.window(from: 140, count: 20)
    #expect(slice.count == 20)
    #expect(slice.first?.textContent == "m140")
    #expect(slice.last?.textContent == "a9")
  }

  @Test func manyTruncationsTriggerInternalRebalance() {
    // Repeatedly truncate and re-append to exercise Rope internal rebalancing.
    var rope = MessageRope()
    for cycle in 0..<20 {
      for i in 0..<100 {
        rope.append(msg(role: .user, content: "c\(cycle)-m\(i)"))
      }
      rope.truncate(to: 50)
      #expect(rope.count == 50)
    }
    // Final state
    #expect(rope.count == 50)
    let slice = rope.window(from: 0, count: 5)
    #expect(slice.count == 5)
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

  // MARK: - Subscript

  @Test func subscriptReturnsMessageAtIndex() {
    let rope = MessageRope((0..<50).map { msg(role: .user, content: "m\($0)") })
    #expect(rope[0].textContent == "m0")
    #expect(rope[25].textContent == "m25")
    #expect(rope[49].textContent == "m49")
  }

  @Test func subscriptCrossesLeafBoundary() {
    // 100 messages spans multiple 32-msg leaves; index 31 and 32 sit on a
    // leaf boundary so this catches any off-by-one in window().
    let rope = MessageRope((0..<100).map { msg(role: .user, content: "m\($0)") })
    #expect(rope[31].textContent == "m31")
    #expect(rope[32].textContent == "m32")
    #expect(rope[63].textContent == "m63")
    #expect(rope[64].textContent == "m64")
  }

  // MARK: - Splice

  @Test func spliceReplacesRange() {
    var rope = MessageRope((0..<10).map { msg(role: .user, content: "m\($0)") })
    rope.splice(3..<7, with: [msg(role: .assistant, content: "summary")])
    #expect(rope.count == 7)  // 10 - 4 removed + 1 added
    #expect(rope[2].textContent == "m2")
    #expect(rope[3].textContent == "summary")
    #expect(rope[4].textContent == "m7")
    #expect(rope[6].textContent == "m9")
  }

  @Test func spliceEmptyReplacementDeletes() {
    var rope = MessageRope((0..<10).map { msg(role: .user, content: "m\($0)") })
    rope.splice(2..<5, with: [])
    #expect(rope.count == 7)
    #expect(rope[1].textContent == "m1")
    #expect(rope[2].textContent == "m5")
  }

  @Test func spliceWholeRangeReplacesAll() {
    var rope = MessageRope((0..<10).map { msg(role: .user, content: "m\($0)") })
    rope.splice(0..<10, with: [msg(role: .system, content: "fresh")])
    #expect(rope.count == 1)
    #expect(rope[0].textContent == "fresh")
  }

  @Test func spliceAtEndIsAppend() {
    var rope = MessageRope((0..<3).map { msg(role: .user, content: "m\($0)") })
    rope.splice(3..<3, with: [msg(role: .assistant, content: "tail")])
    #expect(rope.count == 4)
    #expect(rope.last?.textContent == "tail")
  }

  // MARK: - safeForkBoundaries

  @Test func safeForkBoundariesAllSafe() {
    var rope = MessageRope()
    rope.append(msg(role: .system, content: "sys"))
    rope.append(msg(role: .user, content: "q"))
    rope.append(msg(role: .assistant, content: "a"))
    // Every index closes cleanly — no open tool calls anywhere.
    #expect(rope.safeForkBoundaries() == [1, 2, 3])
  }

  @Test func safeForkBoundariesExcludesMidToolRound() {
    var rope = MessageRope()
    rope.append(msg(role: .system, content: "sys"))
    rope.append(msg(role: .user, content: "q"))
    rope.append(
      msg(
        role: .assistant, content: "",
        toolCalls: [
          .init(id: "t1", _type: "function", function: .init(name: "shell", arguments: "{}"))
        ]))
    rope.append(msg(role: .tool, content: "ok", toolCallId: "t1"))
    rope.append(msg(role: .assistant, content: "done"))
    // Indices 3 (between assistant tool_calls and tool result) is unsafe.
    let boundaries = rope.safeForkBoundaries()
    #expect(!boundaries.contains(3))
    #expect(boundaries.contains(1))
    #expect(boundaries.contains(2))
    #expect(boundaries.contains(4))
    #expect(boundaries.contains(5))
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
      content: .case1(content),
      name: nil,
      toolCalls: toolCalls,
      toolCallId: toolCallId,
      reasoningContent: nil
    )
  }
}

// MARK: - MessageSummaryTests

@Suite
struct MessageSummaryTests {

  @Test func zeroIsZero() {
    #expect(MessageSummary.zero.isZero)
  }

  @Test func nonZeroIsNotZero() {
    #expect(!MessageSummary(count: 5).isZero)
  }

  @Test func add() {
    var s = MessageSummary(count: 3)
    s.add(MessageSummary(count: 7))
    #expect(s.count == 10)
  }

  @Test func subtract() {
    var s = MessageSummary(count: 10)
    s.subtract(MessageSummary(count: 4))
    #expect(s.count == 6)
  }

  @Test func maxNodeSize() {
    #expect(MessageSummary.maxNodeSize == 32)
  }
}

// MARK: - MessageTests

@Suite
struct MessageTests {

  // MARK: - Init

  @Test func emptyInit() {
    let m = Message()
    #expect(m.isEmpty)
    #expect(m.messages.isEmpty)
  }

  @Test func messagesInit() {
    let msgs = [
      msg(role: .system, content: "sys"),
      msg(role: .user, content: "u"),
    ]
    let m = Message(messages: msgs)
    #expect(m.messages.count == 2)
    #expect(!m.isEmpty)
  }

  // MARK: - isEmpty / isUndersized

  @Test func isEmptyTrue() {
    let m = Message()
    #expect(m.isEmpty)
  }

  @Test func isEmptyFalse() {
    let m = Message(messages: [msg(role: .user, content: "hi")])
    #expect(!m.isEmpty)
  }

  @Test func isUndersizedTrueWhenEmpty() {
    let m = Message()
    #expect(m.isUndersized)
  }

  @Test func isUndersizedFalseWhenNotEmpty() {
    let m = Message(messages: [msg(role: .user, content: "hi")])
    #expect(!m.isUndersized)
  }

  // MARK: - Summary

  @Test func summaryReflectsCount() {
    let m = Message(messages: (0..<5).map { msg(role: .user, content: "m\($0)") })
    #expect(m.summary.count == 5)
  }

  @Test func summaryIsZeroForEmpty() {
    let m = Message()
    #expect(m.summary.isZero)
  }

  // MARK: - invariantCheck

  @Test func invariantCheckDoesNotCrashForValidLeaf() {
    let m = Message(messages: (0..<16).map { msg(role: .user, content: "m\($0)") })
    // Must not trap for a leaf within maxNodeSize.
    m.invariantCheck()
  }

  // MARK: - Equatable

  @Test func equalWhenSameMessages() {
    let a = Message(messages: [msg(role: .user, content: "hi")])
    let b = Message(messages: [msg(role: .user, content: "hi")])
    #expect(a == b)
  }

  @Test func notEqualDifferentCount() {
    let a = Message(messages: [msg(role: .user, content: "hi")])
    let b = Message(messages: [msg(role: .user, content: "hi"), msg(role: .assistant, content: "bye")])
    #expect(a != b)
  }

  @Test func notEqualDifferentRole() {
    let a = Message(messages: [msg(role: .user, content: "hi")])
    let b = Message(messages: [msg(role: .assistant, content: "hi")])
    #expect(a != b)
  }

  @Test func notEqualDifferentContent() {
    let a = Message(messages: [msg(role: .user, content: "hi")])
    let b = Message(messages: [msg(role: .user, content: "bye")])
    #expect(a != b)
  }

  @Test func equalEmptyMessages() {
    #expect(Message() == Message())
  }

  // MARK: - Split

  @Test func splitAtMiddle() {
    var left = Message(messages: (0..<10).map { msg(role: .user, content: "m\($0)") })
    let right = left.split(at: 5)
    #expect(left.messages.count == 5)
    #expect(right.messages.count == 5)
    #expect(left.messages.last?.textContent == "m4")
    #expect(right.messages.first?.textContent == "m5")
  }

  @Test func splitAtZero() {
    var left = Message(messages: [msg(role: .user, content: "only")])
    let right = left.split(at: 0)
    #expect(left.messages.isEmpty)
    #expect(right.messages.count == 1)
    #expect(right.messages.first?.textContent == "only")
  }

  @Test func splitAtEnd() {
    var left = Message(messages: [msg(role: .user, content: "only")])
    let right = left.split(at: 1)
    #expect(left.messages.count == 1)
    #expect(right.messages.isEmpty)
  }

  // MARK: - Rebalance nextNeighbor

  @Test func rebalanceNextNeighborSelfEmptyPullsFromRight() {
    var selfMsg = Message()
    var right = Message(messages: (0..<20).map { msg(role: .user, content: "r\($0)") })
    let rightBecameEmpty = selfMsg.rebalance(nextNeighbor: &right)
    // Self was empty (undersized), maxNodeSize/2 = 16. Should pull 16 from right.
    #expect(!rightBecameEmpty)
    #expect(selfMsg.messages.count == 16)
    #expect(selfMsg.messages.first?.textContent == "r0")
    #expect(selfMsg.messages.last?.textContent == "r15")
    #expect(right.messages.count == 4)
    #expect(right.messages.first?.textContent == "r16")
  }

  @Test func rebalanceNextNeighborSelfHasMessagesRightEmptyPushesToRight() {
    var selfMsg = Message(messages: (0..<20).map { msg(role: .user, content: "s\($0)") })
    var right = Message()
    let rightBecameEmpty = selfMsg.rebalance(nextNeighbor: &right)
    // Right was empty (undersized), self has 20, give = 20 - 16 = 4.
    #expect(!rightBecameEmpty)
    #expect(selfMsg.messages.count == 16)
    #expect(selfMsg.messages.last?.textContent == "s15")
    #expect(right.messages.count == 4)
    #expect(right.messages.first?.textContent == "s16")
  }

  @Test func rebalanceNextNeighborBothHaveContentNoOp() {
    var selfMsg = Message(messages: (0..<16).map { msg(role: .user, content: "s\($0)") })
    var right = Message(messages: (0..<16).map { msg(role: .user, content: "r\($0)") })
    let rightBecameEmpty = selfMsg.rebalance(nextNeighbor: &right)
    #expect(!rightBecameEmpty)
    #expect(selfMsg.messages.count == 16)
    #expect(right.messages.count == 16)
  }

  @Test func rebalanceNextNeighborBothEmptyReturnsTrue() {
    var selfMsg = Message()
    var right = Message()
    let rightBecameEmpty = selfMsg.rebalance(nextNeighbor: &right)
    #expect(rightBecameEmpty)
    #expect(selfMsg.messages.isEmpty)
    #expect(right.messages.isEmpty)
  }

  // MARK: - Rebalance prevNeighbor

  @Test func rebalancePrevNeighborLeftEmptyPullsNoSwapWhenSelfNotEmpty() {
    // left empty, self has 20. left pulls 16 from self, self keeps 4.
    // right (self) is not empty so left.rebalance returns false → no swap.
    var left = Message()
    var selfMsg = Message(messages: (0..<20).map { msg(role: .user, content: "s\($0)") })
    let result = selfMsg.rebalance(prevNeighbor: &left)
    #expect(!result)
    #expect(left.messages.count == 16)
    #expect(left.messages.first?.textContent == "s0")
    #expect(selfMsg.messages.count == 4)
    #expect(selfMsg.messages.first?.textContent == "s16")
  }

  @Test func rebalancePrevNeighborLeftEmptySwapsWhenSelfBecomesEmpty() {
    // left empty, self has 1. left pulls 1 from self, self becomes empty.
    // left.rebalance returns true → swap occurs.
    var left = Message()
    var selfMsg = Message(messages: [msg(role: .user, content: "only")])
    let result = selfMsg.rebalance(prevNeighbor: &left)
    #expect(result)
    // After swap: self has the message, left is empty.
    #expect(selfMsg.messages.count == 1)
    #expect(selfMsg.messages.first?.textContent == "only")
    #expect(left.messages.isEmpty)
  }

  @Test func rebalancePrevNeighborBothHaveContentNoOp() {
    var left = Message(messages: (0..<16).map { msg(role: .user, content: "l\($0)") })
    var selfMsg = Message(messages: (0..<16).map { msg(role: .user, content: "s\($0)") })
    let result = selfMsg.rebalance(prevNeighbor: &left)
    #expect(!result)
    #expect(left.messages.count == 16)
    #expect(selfMsg.messages.count == 16)
  }

  // MARK: - Helpers

  private func msg(
    role: Components.Schemas.ChatMessage.RolePayload,
    content: String
  ) -> Components.Schemas.ChatMessage {
    .init(
      role: role,
      content: .case1(content),
      name: nil,
      toolCalls: nil,
      toolCallId: nil,
      reasoningContent: nil
    )
  }
}

// Test-local accessor: pulls the plain-text branch of `ChatMessage.content`
// (the only branch the rope tests construct).
extension Components.Schemas.ChatMessage {
  fileprivate var textContent: String? {
    if case .case1(let s) = content { return s }
    return nil
  }
}
