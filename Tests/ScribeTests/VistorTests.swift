import Testing

@testable import Demo
@testable import Scribe

/// Tests and validates the block structure produced by the [BlockParser](Sources/Scribe/DSL/BlockParser.swift).
@MainActor  // UI Block test run on main thread.
@Suite("Visitor Tests")
struct VisitorTests {

  @Test func visitOptional() async throws {
    let block = OptionalBlock()
    var visitor = TestAllVisitor()
    visitor.visit(block)
    let expected = [
      "visitBlock(_:):OptionalBlock", "visitTuple(_:)", "visitBlock(_:):String",
      "OptionalBlock(idk: Optional(\"Hello\"))", "visitArray(_:)", "visitBlock(_:):String", "Hello",
    ]
    #expect(expected == visitor.visited)
  }

  @Test func visitEntry() async throws {
    let block = Entry()
    var visitor = TestAllVisitor()
    visitor.visit(block)
    let expected = [
      "visitBlock(_:):Entry", "visitTuple(_:)", "visitModified(_:)", "visitBlock(_:):String",
      "Hello, I am Scribe.", "visitModified(_:)", "visitBlock(_:):String", "Zane was here :0",
      "visitModified(_:)", "visitBlock(_:):String", "Job running: ready", "visitBlock(_:):Nested",
      "visitBlock(_:):String", "Nested[text: Hello]",
    ]
    #expect(expected == visitor.visited)
  }

  // Visit all blocks of the ``All`` ``Block`` to verify that all paths are being reached.
  @Test func visitAll() async throws {
    let block = All()
    var visitor = TestAllVisitor()
    visitor.visit(block)
    let expected = [
      "visitBlock(_:):All", "visitTuple(_:)", "visitModified(_:)", "visitBlock(_:):String",
      "Button", "visitBlock(_:):String", "A", "visitArray(_:)", "visitBlock(_:):String", "Zane",
      "visitBlock(_:):String", "Was", "visitBlock(_:):String", "Here",
    ]
    #expect(expected == visitor.visited)
  }

  @Test func visitAllBeforeAfter() async throws {
    let block = All()
    var visitor = TestAllBeforeAfterVisitor()
    visitor.visit(block)
    let expected = [
      "beforeBlock(_:)", "beforeTuple(_:)", "beforeModified(_:)", "beforeBlock(_:)", "Button",
      "afterBlock(_:)", "afterModified(_:)", "beforeBlock(_:)", "A", "afterBlock(_:)",
      "beforeArray(_:)", "beforeBlock(_:)", "Zane", "afterBlock(_:)", "beforeBlock(_:)", "Was",
      "afterBlock(_:)", "beforeBlock(_:)", "Here", "afterBlock(_:)", "afterArray(_:)",
      "afterTuple(_:)", "afterBlock(_:)",
    ]
    #expect(expected == visitor.visited)
  }
}

struct TestAllBeforeAfterVisitor: Visitor {
  var visited: [String] = []

  mutating func visitText(_ text: Text) {
    visited.append(text.text)
  }

  mutating func beforeTuple<each Component: Block>(_ tuple: _TupleBlock<repeat each Component>) {
    visited.append("\(#function)")
  }
  mutating func afterTuple<each Component: Block>(_ tuple: _TupleBlock<repeat each Component>) {
    visited.append("\(#function)")
  }

  mutating func beforeArray<B: Block>(_ array: _ArrayBlock<B>) {
    visited.append("\(#function)")
  }
  mutating func afterArray<B: Block>(_ array: _ArrayBlock<B>) {
    visited.append("\(#function)")
  }

  mutating func beforeModified<W: Block>(_ modified: Modified<W>) {
    visited.append("\(#function)")
  }
  mutating func afterModified<W: Block>(_ modified: Modified<W>) {
    visited.append("\(#function)")
  }

  mutating func beforeBlock(_ block: some Block) {
    visited.append("\(#function)")
  }
  mutating func afterBlock(_ block: some Block) {
    visited.append("\(#function)")
  }
}

struct TestAllVisitor: RawVisitor {
  var visited: [String] = []

  mutating func visitText(_ text: Text) {
    visited.append(text.text)
  }

  mutating func visitTuple<each Component: Block>(_ tuple: _TupleBlock<repeat each Component>) {
    visited.append("\(#function)")
    for child in repeat (each tuple.children) {
      visit(child)
    }
  }

  mutating func visitArray<B: Block>(_ array: _ArrayBlock<B>) {
    visited.append("\(#function)")
    for child in array.children {
      visit(child)
    }
  }

  mutating func visitModified<W: Block>(_ modified: Modified<W>) {
    visited.append("\(#function)")
    visit(modified.wrapped)
  }

  mutating func visitBlock(_ block: some Block) {
    visited.append("\(#function):\(type(of: block))")
    visit(block.component)
  }
}
