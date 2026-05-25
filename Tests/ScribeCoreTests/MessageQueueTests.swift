import Foundation
import ScribeCore
import Testing

@Suite
struct MessageQueueTests {

  @Test func enqueueRejectsBlankText() {
    var queue = PendingMessageQueue()
    #expect(queue.enqueue(text: "   ") == false)
    #expect(queue.isEmpty)
  }

  @Test func drainOneAtATimeReturnsOldestFirst() {
    var queue = PendingMessageQueue(mode: .oneAtATime)
    queue.enqueue(text: "first")
    queue.enqueue(text: "second")

    let first = queue.drain()
    #expect(first.count == 1)
    #expect(first[0].content == "first")
    #expect(queue.count == 1)

    let second = queue.drain()
    #expect(second[0].content == "second")
    #expect(queue.isEmpty)
  }

  @Test func drainAllEmptiesQueue() {
    var queue = PendingMessageQueue(mode: .all)
    queue.enqueue(text: "a")
    queue.enqueue(text: "b")

    let drained = queue.drain()
    #expect(drained.map(\.content) == ["a", "b"])
    #expect(queue.isEmpty)
  }

  @Test func popFirstForRecall() {
    var queue = PendingMessageQueue()
    queue.enqueue(text: "keep")
    queue.enqueue(text: "next")
    #expect(queue.popFirst()?.content == "keep")
    #expect(queue.previewTexts == ["next"])
  }
}
