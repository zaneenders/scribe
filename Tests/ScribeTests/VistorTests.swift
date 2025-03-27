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
    walker.walk(block.optimizeTree())
    let expected = [
      "walkGroup(_:)", "walkGroup(_:)", "walkWrapped(_:_:_:), i true", "walkText(_:): A",
      "walkGroup(_:)", "walkText(_:): Zane", "walkText(_:): Was", "walkText(_:): Here",
    ]
    #expect(expected == walker.visited)
  }

  @Test func visitOptional() async throws {
    let block = OptionalBlock()
    var walker = TestAllWalker()
    walker.walk(block.optimizeTree())
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
    walker.walk(block.optimizeTree())
    let expected = ["walkGroup(_:)", "walkGroup(_:)", "walkText(_:): Hello", "walkText(_:): Zane"]
    #expect(expected == walker.visited)
  }

  // Visit all blocks of the ``All`` ``Block`` to verify that all paths are being reached.
  @Test func visitSelectionBlock() async throws {
    let block = SelectionBlock()
    var walker = TestAllWalker()
    walker.walk(block.optimizeTree())
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
    walker.walk(block.optimizeTree())
    let expected = ["walkGroup(_:)", "walkWrapped(_:_:_:), i true"]
    #expect(expected == walker.visited)
  }

  @Test func visitEntry() async throws {
    let block = Entry()

    var walker = TestAllWalker()
    walker.walk(block.optimizeTree())
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
    walker.walk(block.optimizeTree())
    let expected = [
      "beforeGroup(_:)", "beforeGroup(_:)", "beforeWrapped(_:_:_:)", "walkText(_:)",
      "afterWrapped(_:_:_:)", "walkText(_:)", "beforeGroup(_:)", "walkText(_:)", "walkText(_:)",
      "walkText(_:)", "afterGroup(_:)", "afterGroup(_:)", "afterGroup(_:)",
    ]
    #expect(expected == walker.visited)
  }
}

struct TestAllBeforeAfterWalker: L2HashWalker {
  mutating func beforeGroup(_ group: [L2Element], _ binding: L2Binding?) {
    visited.append("\(#function)")
  }

  mutating func afterGroup(_ group: [L2Element], _ binding: L2Binding?) {
    visited.append("\(#function)")
  }

  mutating func walkText(_ text: String, _ binding: L2Binding?) {
    visited.append("\(#function)")
  }

  var currentHash: Hash = hash(contents: "0")
  var visited: [String] = []
}

struct TestAllWalker: L2ElementWalker {
  mutating func walkText(_ text: String, _ binding: L2Binding?) {
    visited.append("\(#function): \(text), \(binding)")
  }

  mutating func walkGroup(_ group: [L2Element], _ binding: L2Binding?) {
    visited.append("\(#function), \(binding)")
    for child in group {
      walk(child)
    }
  }

  var visited: [String] = []
}
