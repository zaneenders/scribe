import Testing
import _RopeModule

@testable import ScribeCLI

/// Tests for `BigString` cursor-relative operations (insert, backspace, cursor
/// navigation) — the building blocks used by `SlateChatHost` for edit-mode
/// text manipulation.
@Suite
struct BigStringCursorTests {

  // MARK: - Empty buffer

  @Test func emptyBufferHasStartEqualToEnd() {
    let buf = BigString()
    #expect(buf.startIndex == buf.endIndex)
    #expect(buf.count == 0)
    #expect(String(buf) == "")
  }

  // MARK: - Insert

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
    var cursor = buf.index(after: buf.startIndex)  // between 'a' and 'c'

    buf.insert(contentsOf: "b", at: cursor)
    cursor = buf.index(after: cursor)

    #expect(String(buf) == "abc")
    // Cursor should now be at the 'c' position, not at endIndex
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

  // MARK: - Backspace (delete backward)

  @Test func backspaceFromEmptyBufferIsNoop() {
    var buf = BigString()
    let cursor = buf.startIndex

    // Should not crash, and should not change anything
    guard cursor > buf.startIndex else {
      // Simulating the guard in deleteBackward: if cursor == startIndex, skip
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
    // Cursor after 'b'
    let first = buf.index(after: buf.startIndex)
    var cursor = buf.index(after: first)  // after 'b', before 'c'

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

    // Backspace twice: "hello" → "hel"
    for _ in 0..<2 {
      let prev = buf.index(before: cursor)
      buf.removeSubrange(prev..<cursor)
      cursor = prev
    }
    #expect(String(buf) == "hel")

    // Insert "p" at cursor → "help"
    buf.insert(contentsOf: "p", at: cursor)
    cursor = buf.index(after: cursor)
    #expect(String(buf) == "help")
    #expect(cursor == buf.endIndex)
  }

  // MARK: - Cursor navigation

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

  // MARK: - Multi-codepoint characters

  @Test func insertAndRemoveEmoji() {
    var buf = BigString()
    var cursor = buf.startIndex

    // Insert an emoji (multi-codepoint)
    buf.insert(contentsOf: "🚀", at: cursor)
    cursor = buf.index(after: cursor)

    #expect(String(buf) == "🚀")
    #expect(buf.count == 1)  // single Character
    #expect(cursor == buf.endIndex)

    // Backspace the emoji
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
    #expect(buf.count == 4)  // "c", "a", "f", "é"

    // Backspace twice → "ca"
    for _ in 0..<2 {
      let prev = buf.index(before: cursor)
      buf.removeSubrange(prev..<cursor)
      cursor = prev
    }
    #expect(String(buf) == "ca")
    #expect(buf.count == 2)
  }

  // MARK: - New buffer from replacement

  @Test func replacingBufferAfterSubmitPreservesNewCursor() {
    // Simulate submitUserLine: create new BigString, reset cursor
    var buf = BigString()
    buf.insert(contentsOf: "old", at: buf.startIndex)
    #expect(String(buf) == "old")

    // "Submit" — replace buffer
    buf = BigString()
    let cursor = buf.startIndex
    #expect(String(buf) == "")
    #expect(cursor == buf.startIndex)
    #expect(cursor == buf.endIndex)
  }

  // MARK: - Recall queue into buffer

  @Test func recallQueuedMessageSetsBufferAndCursorToEnd() {
    let queued = "recalled message"
    var buf = BigString()
    buf.insert(contentsOf: queued, at: buf.startIndex)
    let cursor = buf.endIndex

    #expect(String(buf) == queued)
    #expect(cursor == buf.endIndex)
    #expect(buf.count == queued.count)
  }

  // MARK: - Edge cases

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

    // Build a string incrementally
    for ch in "hello world" {
      buf.insert(contentsOf: String(ch), at: cursor)
      cursor = buf.index(after: cursor)
    }
    #expect(String(buf) == "hello world")

    // Delete back to "hello"
    while String(buf) != "hello" {
      let prev = buf.index(before: cursor)
      buf.removeSubrange(prev..<cursor)
      cursor = prev
    }
    #expect(String(buf) == "hello")
    #expect(buf.count == 5)
  }
}
