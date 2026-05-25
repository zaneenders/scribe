import ScribeCore
import Testing

@Suite
struct MessageRopeTests {


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


  @Test func firstAndLast() {
    var rope = MessageRope()
    rope.append(msg(role: .system, content: "first"))
    rope.append(msg(role: .user, content: "middle"))
    rope.append(msg(role: .assistant, content: "last"))
    #expect(rope.first?.content == "first")
    #expect(rope.last?.content == "last")
  }


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


  @Test func forEachWalksAll() {
    let msgs = (0..<128).map { msg(role: .user, content: "m\($0)") }
    let rope = MessageRope(msgs)
    var seen: [String] = []
    rope.forEach { seen.append($0.content) }
    #expect(seen.count == 128)
    #expect(seen.first == "m0")
    #expect(seen.last == "m127")
  }


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
              ScribeToolCall(id: "t\(turn)", name: "shell", arguments: "{}")
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
    #expect(slice.first?.content == "m0")
    #expect(slice.last?.content == "m49")
  }


  @Test func truncateToSameCountIsNoOp() {
    var rope = MessageRope((0..<50).map { msg(role: .user, content: "m\($0)") })
    rope.truncate(to: 50)
    #expect(rope.count == 50)
    #expect(rope.last?.content == "m49")
  }

  @Test func truncateToGreaterCountIsNoOp() {
    var rope = MessageRope((0..<10).map { msg(role: .user, content: "m\($0)") })
    rope.truncate(to: 100)
    #expect(rope.count == 10)
    #expect(rope.last?.content == "m9")
  }

  @Test func truncateFromOneToZeroThenAppend() {
    var rope = MessageRope()
    rope.append(msg(role: .user, content: "only"))
    rope.truncate(to: 0)
    #expect(rope.isEmpty)
    rope.append(msg(role: .assistant, content: "after"))
    #expect(rope.count == 1)
    #expect(rope.first?.content == "after")
  }


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
    #expect(rope.last?.content == "m149")
    // Append more
    for i in 0..<50 {
      rope.append(msg(role: .assistant, content: "a\(i)"))
    }
    #expect(rope.count == 200)
    #expect(rope.last?.content == "a49")
    // Window still works
    let slice = rope.window(from: 140, count: 20)
    #expect(slice.count == 20)
    #expect(slice.first?.content == "m140")
    #expect(slice.last?.content == "a9")
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


  @Test func subscriptReturnsMessageAtIndex() {
    let rope = MessageRope((0..<50).map { msg(role: .user, content: "m\($0)") })
    #expect(rope[0].content == "m0")
    #expect(rope[25].content == "m25")
    #expect(rope[49].content == "m49")
  }

  @Test func subscriptCrossesLeafBoundary() {
    // 100 messages spans multiple 32-msg leaves; index 31 and 32 sit on a
    // leaf boundary so this catches any off-by-one in window().
    let rope = MessageRope((0..<100).map { msg(role: .user, content: "m\($0)") })
    #expect(rope[31].content == "m31")
    #expect(rope[32].content == "m32")
    #expect(rope[63].content == "m63")
    #expect(rope[64].content == "m64")
  }


  @Test func spliceReplacesRange() {
    var rope = MessageRope((0..<10).map { msg(role: .user, content: "m\($0)") })
    rope.splice(3..<7, with: [msg(role: .assistant, content: "summary")])
    #expect(rope.count == 7)  // 10 - 4 removed + 1 added
    #expect(rope[2].content == "m2")
    #expect(rope[3].content == "summary")
    #expect(rope[4].content == "m7")
    #expect(rope[6].content == "m9")
  }

  @Test func spliceEmptyReplacementDeletes() {
    var rope = MessageRope((0..<10).map { msg(role: .user, content: "m\($0)") })
    rope.splice(2..<5, with: [])
    #expect(rope.count == 7)
    #expect(rope[1].content == "m1")
    #expect(rope[2].content == "m5")
  }

  @Test func spliceWholeRangeReplacesAll() {
    var rope = MessageRope((0..<10).map { msg(role: .user, content: "m\($0)") })
    rope.splice(0..<10, with: [msg(role: .system, content: "fresh")])
    #expect(rope.count == 1)
    #expect(rope[0].content == "fresh")
  }

  @Test func spliceAtEndIsAppend() {
    var rope = MessageRope((0..<3).map { msg(role: .user, content: "m\($0)") })
    rope.splice(3..<3, with: [msg(role: .assistant, content: "tail")])
    #expect(rope.count == 4)
    #expect(rope.last?.content == "tail")
  }


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
          ScribeToolCall(id: "t1", name: "shell", arguments: "{}")
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


  private func msg(
    role: ScribeMessage.Role,
    content: String,
    toolCalls: [ScribeToolCall]? = nil,
    toolCallId: String? = nil
  ) -> ScribeMessage {
    ScribeMessage(
      role: role,
      content: content,
      toolCalls: toolCalls,
      toolCallId: toolCallId
    )
  }
}


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


@Suite
struct MessageTests {


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


  @Test func summaryReflectsCount() {
    let m = Message(messages: (0..<5).map { msg(role: .user, content: "m\($0)") })
    #expect(m.summary.count == 5)
  }

  @Test func summaryIsZeroForEmpty() {
    let m = Message()
    #expect(m.summary.isZero)
  }


  @Test func invariantCheckDoesNotCrashForValidLeaf() {
    let m = Message(messages: (0..<16).map { msg(role: .user, content: "m\($0)") })
    // Must not trap for a leaf within maxNodeSize.
    m.invariantCheck()
  }


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


  @Test func splitAtMiddle() {
    var left = Message(messages: (0..<10).map { msg(role: .user, content: "m\($0)") })
    let right = left.split(at: 5)
    #expect(left.messages.count == 5)
    #expect(right.messages.count == 5)
    #expect(left.messages.last?.content == "m4")
    #expect(right.messages.first?.content == "m5")
  }

  @Test func splitAtZero() {
    var left = Message(messages: [msg(role: .user, content: "only")])
    let right = left.split(at: 0)
    #expect(left.messages.isEmpty)
    #expect(right.messages.count == 1)
    #expect(right.messages.first?.content == "only")
  }

  @Test func splitAtEnd() {
    var left = Message(messages: [msg(role: .user, content: "only")])
    let right = left.split(at: 1)
    #expect(left.messages.count == 1)
    #expect(right.messages.isEmpty)
  }


  @Test func rebalanceNextNeighborSelfEmptyPullsFromRight() {
    var selfMsg = Message()
    var right = Message(messages: (0..<20).map { msg(role: .user, content: "r\($0)") })
    let rightBecameEmpty = selfMsg.rebalance(nextNeighbor: &right)
    // Self was empty (undersized), maxNodeSize/2 = 16. Should pull 16 from right.
    #expect(!rightBecameEmpty)
    #expect(selfMsg.messages.count == 16)
    #expect(selfMsg.messages.first?.content == "r0")
    #expect(selfMsg.messages.last?.content == "r15")
    #expect(right.messages.count == 4)
    #expect(right.messages.first?.content == "r16")
  }

  @Test func rebalanceNextNeighborSelfHasMessagesRightEmptyPushesToRight() {
    var selfMsg = Message(messages: (0..<20).map { msg(role: .user, content: "s\($0)") })
    var right = Message()
    let rightBecameEmpty = selfMsg.rebalance(nextNeighbor: &right)
    // Right was empty (undersized), self has 20, give = 20 - 16 = 4.
    #expect(!rightBecameEmpty)
    #expect(selfMsg.messages.count == 16)
    #expect(selfMsg.messages.last?.content == "s15")
    #expect(right.messages.count == 4)
    #expect(right.messages.first?.content == "s16")
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


  @Test func rebalancePrevNeighborLeftEmptyPullsNoSwapWhenSelfNotEmpty() {
    // left empty, self has 20. left pulls 16 from self, self keeps 4.
    // right (self) is not empty so left.rebalance returns false → no swap.
    var left = Message()
    var selfMsg = Message(messages: (0..<20).map { msg(role: .user, content: "s\($0)") })
    let result = selfMsg.rebalance(prevNeighbor: &left)
    #expect(!result)
    #expect(left.messages.count == 16)
    #expect(left.messages.first?.content == "s0")
    #expect(selfMsg.messages.count == 4)
    #expect(selfMsg.messages.first?.content == "s16")
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
    #expect(selfMsg.messages.first?.content == "only")
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


  private func msg(
    role: ScribeMessage.Role,
    content: String
  ) -> ScribeMessage {
    ScribeMessage(role: role, content: content)
  }
}
