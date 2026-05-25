import Testing
import _RopeModule

@testable import ScribeCLI

@Suite
struct BigStringCursorTests {

  @Test func emptyBufferHasStartEqualToEnd() {
    let buf = BigString()
    #expect(buf.startIndex == buf.endIndex)
    #expect(buf.count == 0)
    #expect(String(buf) == "")
  }

  @Test func insertAtStartOfEmptyBuffer() {
    var buf = BigString()
    var cursor = buf.startIndex
    buf.insert(contentsOf: "a", at: cursor)
    cursor = buf.index(after: cursor)

    #expect(String(buf) == "a")
    #expect(buf.count == 1)
    #expect(cursor == buf.endIndex)
  }

  @Test func insertMultipleCharsAtStart() {
    var buf = BigString()
    var cursor = buf.startIndex

    buf.insert(contentsOf: "h", at: cursor)
    cursor = buf.index(after: cursor)
    buf.insert(contentsOf: "i", at: cursor)
    cursor = buf.index(after: cursor)

    #expect(String(buf) == "hi")
    #expect(cursor == buf.endIndex)
  }

  @Test func insertAtMiddleOfBuffer() {
    var buf = BigString()
    buf.insert(contentsOf: "ac", at: buf.startIndex)
    var cursor = buf.index(after: buf.startIndex)

    buf.insert(contentsOf: "b", at: cursor)
    cursor = buf.index(after: cursor)

    #expect(String(buf) == "abc")

    #expect(buf[cursor] == "c")
  }

  @Test func insertAtEndOfBuffer() {
    var buf = BigString()
    buf.insert(contentsOf: "ab", at: buf.startIndex)
    var cursor = buf.endIndex

    buf.insert(contentsOf: "c", at: cursor)
    cursor = buf.index(after: cursor)

    #expect(String(buf) == "abc")
    #expect(cursor == buf.endIndex)
  }

  @Test func insertNewline() {
    var buf = BigString()
    var cursor = buf.startIndex

    buf.insert(contentsOf: "line1", at: cursor)
    cursor = buf.endIndex
    buf.insert(contentsOf: "\n", at: cursor)
    cursor = buf.index(after: cursor)
    buf.insert(contentsOf: "line2", at: cursor)
    cursor = buf.endIndex

    #expect(String(buf) == "line1\nline2")
    #expect(buf.count == 11)
  }

  @Test func backspaceFromEmptyBufferIsNoop() {
    var buf = BigString()
    let cursor = buf.startIndex

    guard cursor > buf.startIndex else {

      #expect(String(buf) == "")
      return
    }
    let prev = buf.index(before: cursor)
    buf.removeSubrange(prev..<cursor)
    #expect(String(buf) == "")
  }

  @Test func backspaceFromEndRemovesLastChar() {
    var buf = BigString()
    buf.insert(contentsOf: "abc", at: buf.startIndex)
    var cursor = buf.endIndex

    let prev = buf.index(before: cursor)
    buf.removeSubrange(prev..<cursor)
    cursor = prev

    #expect(String(buf) == "ab")
    #expect(cursor == buf.endIndex)
  }

  @Test func backspaceFromMiddle() {
    var buf = BigString()
    buf.insert(contentsOf: "abc", at: buf.startIndex)

    let first = buf.index(after: buf.startIndex)
    var cursor = buf.index(after: first)

    let prev = buf.index(before: cursor)
    buf.removeSubrange(prev..<cursor)
    cursor = prev

    #expect(String(buf) == "ac")
    #expect(cursor == buf.index(after: buf.startIndex))
  }

  @Test func backspaceMultipleCharsThenInsert() {
    var buf = BigString()
    buf.insert(contentsOf: "hello", at: buf.startIndex)
    var cursor = buf.endIndex

    for _ in 0..<2 {
      let prev = buf.index(before: cursor)
      buf.removeSubrange(prev..<cursor)
      cursor = prev
    }
    #expect(String(buf) == "hel")

    buf.insert(contentsOf: "p", at: cursor)
    cursor = buf.index(after: cursor)
    #expect(String(buf) == "help")
    #expect(cursor == buf.endIndex)
  }

  @Test func cursorAfterMovesForward() {
    let buf = BigString("abc")
    var cursor = buf.startIndex
    cursor = buf.index(after: cursor)
    #expect(cursor > buf.startIndex)
    #expect(cursor < buf.endIndex)
    cursor = buf.index(after: cursor)
    cursor = buf.index(after: cursor)
    #expect(cursor == buf.endIndex)
  }

  @Test func cursorBeforeMovesBackward() {
    let buf = BigString("abc")
    var cursor = buf.endIndex
    cursor = buf.index(before: cursor)
    #expect(cursor < buf.endIndex)
    #expect(cursor > buf.startIndex)
  }

  @Test func startIndexLessThanEndIndexWhenNonEmpty() {
    let buf = BigString("abc")
    #expect(buf.startIndex < buf.endIndex)
  }

  @Test func insertAndRemoveEmoji() {
    var buf = BigString()
    var cursor = buf.startIndex

    buf.insert(contentsOf: "🚀", at: cursor)
    cursor = buf.index(after: cursor)

    #expect(String(buf) == "🚀")
    #expect(buf.count == 1)
    #expect(cursor == buf.endIndex)

    let prev = buf.index(before: cursor)
    buf.removeSubrange(prev..<cursor)
    cursor = prev

    #expect(String(buf) == "")
    #expect(buf.count == 0)
  }

  @Test func insertAndRemoveCombinedCharacters() {
    var buf = BigString()
    buf.insert(contentsOf: "café", at: buf.startIndex)
    var cursor = buf.endIndex

    #expect(String(buf) == "café")
    #expect(buf.count == 4)

    for _ in 0..<2 {
      let prev = buf.index(before: cursor)
      buf.removeSubrange(prev..<cursor)
      cursor = prev
    }
    #expect(String(buf) == "ca")
    #expect(buf.count == 2)
  }

  @Test func replacingBufferAfterSubmitPreservesNewCursor() {

    var buf = BigString()
    buf.insert(contentsOf: "old", at: buf.startIndex)
    #expect(String(buf) == "old")

    buf = BigString()
    let cursor = buf.startIndex
    #expect(String(buf) == "")
    #expect(cursor == buf.startIndex)
    #expect(cursor == buf.endIndex)
  }

  @Test func recallQueuedMessageSetsBufferAndCursorToEnd() {
    let queued = "recalled message"
    var buf = BigString()
    buf.insert(contentsOf: queued, at: buf.startIndex)
    let cursor = buf.endIndex

    #expect(String(buf) == queued)
    #expect(cursor == buf.endIndex)
    #expect(buf.count == queued.count)
  }

  @Test func insertEmptyStringDoesNothing() {
    var buf = BigString()
    let cursor = buf.startIndex
    buf.insert(contentsOf: "", at: cursor)

    #expect(String(buf) == "")
    #expect(buf.count == 0)
  }

  @Test func manyInsertsAndDeletes() {
    var buf = BigString()
    var cursor = buf.startIndex

    for ch in "hello world" {
      buf.insert(contentsOf: String(ch), at: cursor)
      cursor = buf.index(after: cursor)
    }
    #expect(String(buf) == "hello world")

    while String(buf) != "hello" {
      let prev = buf.index(before: cursor)
      buf.removeSubrange(prev..<cursor)
      cursor = prev
    }
    #expect(String(buf) == "hello")
    #expect(buf.count == 5)
  }
}
