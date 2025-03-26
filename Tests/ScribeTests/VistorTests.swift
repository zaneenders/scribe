import Testing

@testable import Demo
@testable import Scribe

/// Tests and validates the block structure produced by the [BlockParser](Sources/Scribe/DSL/BlockParser.swift).
@MainActor  // UI Block test run on main thread.
@Suite("Visitor Tests")
struct VisitorTests {

  @Test func visitAll() async throws {
    let block = All()
    var walker = TestAllWalker()
    walker.walk(block.toL1Element())
    let expected = [
      "walkGroup(_:)", "walkGroup(_:)", "walkWrapped(_:_:_:), i true", "walkText(_:): A",
      "walkGroup(_:)", "walkText(_:): Zane", "walkText(_:): Was", "walkText(_:): Here",
    ]
    #expect(expected == walker.visited)
  }

  @Test func visitOptional() async throws {
    let block = OptionalBlock()
    var walker = TestAllWalker()
    walker.walk(block.toL1Element())
    let expected = [
      "walkGroup(_:)", "walkGroup(_:)", "walkText(_:): OptionalBlock(idk: Optional(\"Hello\"))",
      "walkGroup(_:)", "walkText(_:): Hello",
    ]
    #expect(expected == walker.visited)
  }

  // Visit all blocks of the ``All`` ``Block`` to verify that all paths are being reached.
  @Test func visitBasicText() async throws {
    let block = BasicTupleText()
    var walker = TestAllWalker()
    walker.walk(block.toL1Element())
    let expected = ["walkGroup(_:)", "walkGroup(_:)", "walkText(_:): Hello", "walkText(_:): Zane"]
    #expect(expected == walker.visited)
  }

  // Visit all blocks of the ``All`` ``Block`` to verify that all paths are being reached.
  @Test func visitSelectionBlock() async throws {
    let block = SelectionBlock()
    var walker = TestAllWalker()
    walker.walk(block.toL1Element())
    let expected = [
      "walkGroup(_:)", "walkGroup(_:)", "walkText(_:): Hello", "walkText(_:): Zane",
      "walkText(_:): was", "walkText(_:): here", "walkGroup(_:)", "walkText(_:): 0",
      "walkText(_:): 1", "walkText(_:): 2",
    ]
    #expect(expected == walker.visited)
  }

  @Test func visitAsyncUpdateStateUpdate() async throws {
    let block = AsyncUpdateStateUpdate()
    var walker = TestAllWalker()
    walker.walk(block.toL1Element())
    let expected = ["walkGroup(_:)", "walkWrapped(_:_:_:), i true"]
    #expect(expected == walker.visited)
  }

  @Test func visitEntry() async throws {
    let block = Entry()

    var walker = TestAllWalker()
    walker.walk(block.toL1Element())
    let expected = [
      "walkGroup(_:)", "walkGroup(_:)", "walkWrapped(_:_:_:), i true",
      "walkWrapped(_:_:_:), e true", "walkWrapped(_:_:_:), i true", "walkGroup(_:)",
      "walkText(_:): Nested[text: Hello]",
    ]
    #expect(expected == walker.visited)
  }

  @Test func visitAllBeforeAfter() async throws {
    let block = All()
    var walker = TestAllBeforeAfterWalker()
    walker.walk(block.toL1Element())
    let expected = [
      "beforeGroup(_:)", "beforeGroup(_:)", "beforeWrapped(_:_:_:)", "walkText(_:)",
      "afterWrapped(_:_:_:)", "walkText(_:)", "beforeGroup(_:)", "walkText(_:)", "walkText(_:)",
      "walkText(_:)", "afterGroup(_:)", "afterGroup(_:)", "afterGroup(_:)",
    ]
    #expect(expected == walker.visited)
  }
}

struct TestAllBeforeAfterWalker: L1HashWalker {
  var currentHash: Hash = hash(contents: "0")
  var visited: [String] = []

  mutating func beforeWrapped(_ element: L1Element, _ key: String, _ action: BlockAction?) {
    visited.append("\(#function)")
  }

  mutating func afterWrapped(_ element: L1Element, _ key: String, _ action: BlockAction?) {
    visited.append("\(#function)")
  }

  mutating func beforeGroup(_ group: [L1Element]) {
    visited.append("\(#function)")
  }

  mutating func afterGroup(_ group: [L1Element]) {
    visited.append("\(#function)")
  }

  mutating func beforeComposed(_ composed: L1Element) {
    visited.append("\(#function)")
  }

  mutating func afterComposed(_ composed: L1Element) {
    visited.append("\(#function)")
  }

  mutating func walkText(_ text: String) {
    visited.append("\(#function)")
  }
}

struct TestAllWalker: L1ElementWalker {
  var visited: [String] = []
  mutating func walkWrapped(_ element: L1Element, _ key: String, _ action: BlockAction?) {
    visited.append("\(#function), \(key) \(action != nil)")
  }

  mutating func walkText(_ text: String) {
    visited.append("\(#function): \(text)")
  }

  mutating func walkGroup(_ group: [L1Element]) {
    visited.append("\(#function)")
    for child in group {
      walk(child)
    }
  }
}
