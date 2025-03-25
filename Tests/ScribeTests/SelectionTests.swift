import Testing

@testable import Demo
@testable import Scribe

@MainActor  // UI Block test run on main thread.
@Suite("Selection Tests")
// NOTE: Keep ordered by Demo then BlockSnippets
struct SelectionTests {

  @Test func selectEntry() async throws {
    let block = Entry()
    var container = BlockContainer(block)
    var renderer = TestRenderer()
    container.expectState(
      &renderer,
      expected: [
        "[Hello, I am Scribe.]", "[Job running: ready]", "[Nested[text: Hello]]",
        "[Zane was here :0]",
      ])
    // Move in
    container.testMoveIn(
      &renderer,
      expected: [
        "[Nested[text: Hello]]", "[Zane was here :0]", "[Hello, I am Scribe.]",
        "[Job running: ready]",
      ])

    container.testMoveIn(
      &renderer,
      expected: [
        "[Hello, I am Scribe.]", "Job running: ready", "Nested[text: Hello]", "Zane was here :0",
      ])
    container.action(.lowercaseI)

    container.expectState(
      &renderer,
      expected: [
        "Zane was here :0", "Job running: ready", "[Hello, I am Scribe.!]", "Nested[text: Hello#]",
      ])
  }

  @Test func selectAll() async throws {
    let block = All()
    var container = BlockContainer(block)
    var renderer = TestRenderer()
    container.expectState(&renderer, expected: ["[A]", "[Button]", "[Here]", "[Was]", "[Zane]"])
    // Move in
    container.moveIn()
    container.testMoveIn(
      &renderer,
      expected: ["[Button]", "A", "Zane", "Was", "Here"])
    container.printState(&renderer)
  }

  @Test func selectOptionalBlock() async throws {
    let block = OptionalBlock()
    var container = BlockContainer(block)
    var renderer = TestRenderer()
    container.expectState(
      &renderer, expected: ["[Hello]", "[OptionalBlock(idk: Optional(\"Hello\"))]"])
    // TODO movements
  }

  @Test func selectBasicTupleText() async throws {
    let block = BasicTupleText()
    var container = BlockContainer(block)
    var renderer = TestRenderer()
    container.expectState(&renderer, expected: ["[Hello]", "[Zane]"])
    // TODO movements
  }

  @Test func selectSelectionBlock() async throws {
    let block = SelectionBlock()
    var container = BlockContainer(block)
    var renderer = TestRenderer()
    container.expectState(
      &renderer, expected: ["[0]", "[1]", "[2]", "[Hello]", "[Zane]", "[here]", "[was]"])

    // Move in
    container.testMoveIn(
      &renderer, expected: ["[0]", "[1]", "[2]", "[Hello]", "[Zane]", "[here]", "[was]"])

    // Move in
    container.testMoveIn(&renderer, expected: ["0", "1", "2", "Zane", "[Hello]", "here", "was"])

    // Move in
    container.testMoveIn(&renderer, expected: ["0", "1", "2", "Zane", "[Hello]", "here", "was"])

    // Move in
    container.testMoveIn(&renderer, expected: ["0", "1", "2", "Zane", "[Hello]", "here", "was"])

    // Move Down
    container.testMoveDown(&renderer, expected: ["0", "1", "2", "[Zane]", "Hello", "here", "was"])

    // Move Up
    container.testMoveUp(&renderer, expected: ["0", "1", "2", "Zane", "[Hello]", "here", "was"])

    // Move Down
    container.testMoveDown(&renderer, expected: ["0", "1", "2", "[Zane]", "Hello", "here", "was"])

    // Move Down
    container.testMoveDown(&renderer, expected: ["0", "1", "2", "Zane", "Hello", "here", "[was]"])

    // Move Down
    container.testMoveDown(&renderer, expected: ["0", "1", "2", "Zane", "Hello", "[here]", "was"])

    // Move Down
    container.testMoveDown(
      &renderer, expected: ["[0]", "[1]", "[2]", "Zane", "Hello", "here", "was"])

    // Move Down
    container.testMoveDown(&renderer, expected: ["[0]", "1", "2", "Zane", "Hello", "here", "was"])

    // Move Down
    container.testMoveDown(&renderer, expected: ["0", "[1]", "2", "Zane", "Hello", "here", "was"])

    // Move Down
    container.testMoveDown(&renderer, expected: ["0", "1", "[2]", "Zane", "Hello", "here", "was"])

    // Move Down
    container.testMoveDown(&renderer, expected: ["0", "1", "[2]", "Zane", "Hello", "here", "was"])

    // Move Down
    container.testMoveDown(&renderer, expected: ["0", "1", "[2]", "Zane", "Hello", "here", "was"])

    // Move out
    container.testMoveOut(
      &renderer, expected: ["[0]", "[1]", "[2]", "Zane", "Hello", "here", "was"])

    // Move out
    container.testMoveOut(
      &renderer, expected: ["[0]", "[1]", "[2]", "[Hello]", "[Zane]", "[here]", "[was]"])

    // Move out
    container.testMoveOut(
      &renderer, expected: ["[0]", "[1]", "[2]", "[Hello]", "[Zane]", "[here]", "[was]"])

    // Move out
    container.testMoveOut(
      &renderer, expected: ["[0]", "[1]", "[2]", "[Hello]", "[Zane]", "[here]", "[was]"])
  }

  @Test func selectAsyncUpdateStateUpdate() async throws {

    let firstPause = AsyncUpdateStateUpdate.delay / 2
    let secondPause = AsyncUpdateStateUpdate.delay

    let block = AsyncUpdateStateUpdate()
    var container = BlockContainer(block)
    var renderer = TestRenderer()
    container.expectState(&renderer, expected: ["[ready]"])

    // Move in
    container.testMoveIn(&renderer, expected: ["[ready]"])

    // Action
    container.action(.lowercaseI)
    container.expectState(&renderer, expected: ["[running]"])

    try await Task.sleep(for: .milliseconds(firstPause))
    container.expectState(&renderer, expected: ["[running]"])

    try await Task.sleep(for: .milliseconds(secondPause))
    container.expectState(&renderer, expected: ["[ready]"])
  }
}

// Helper functions to make creating test easier.
extension BlockContainer {
  mutating func moveUp() {
    self.action(.lowercaseF)
  }
  mutating func moveDown() {
    self.action(.lowercaseJ)
  }
  mutating func moveOut() {
    self.action(.lowercaseS)
  }
  mutating func moveIn() {
    self.action(.lowercaseL)
  }

  mutating func testMoveUp(_ renderer: inout TestRenderer, expected: [String]) {
    moveUp()
    expectState(&renderer, expected: expected)
  }

  mutating func testMoveDown(_ renderer: inout TestRenderer, expected: [String]) {
    moveDown()
    expectState(&renderer, expected: expected)
  }

  mutating func testMoveIn(_ renderer: inout TestRenderer, expected: [String]) {
    moveIn()
    expectState(&renderer, expected: expected)
  }

  mutating func testMoveOut(_ renderer: inout TestRenderer, expected: [String]) {
    moveOut()
    expectState(&renderer, expected: expected)
  }

  mutating func expectState(_ renderer: inout TestRenderer, expected: [String]) {
    self.observe(with: &renderer)
    let output = renderer.previousVisitor.textObjects.map { $0.value }
    #expect(output.sorted() == expected.sorted())
  }

  // Helper for creating expected arrays
  mutating func printState(_ renderer: inout TestRenderer) {
    self.observe(with: &renderer)
    let output = renderer.previousVisitor.textObjects.map { $0.value }
    print(output)
  }
}
