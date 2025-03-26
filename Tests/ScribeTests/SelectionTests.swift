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

    container.moveIn()
    container.expectState(
      &renderer,
      expected: [
        "[Nested[text: Hello]]", "[Zane was here :0]", "[Hello, I am Scribe.]",
        "[Job running: ready]",
      ])

    container.moveIn()
    container.expectState(
      &renderer,
      expected: [
        "[Hello, I am Scribe.]", "Job running: ready", "Nested[text: Hello]", "Zane was here :0",
      ])
    container.action(.lowercaseI)
    container.expectState(
      &renderer,
      expected: [
        "Zane was here :0", "Nested[text: Hello#]", "[Hello, I am Scribe.!]", "Job running: ready",
      ])
    container.moveDown()
    container.expectState(
      &renderer,
      expected: [
        "[Zane was here :0]", "Nested[text: Hello#]", "Hello, I am Scribe.!", "Job running: ready",
      ])
    container.action(.lowercaseE)
    container.expectState(
      &renderer,
      expected: [
        "Job running: ready", "[Zane was here :1]", "Nested[text: Hello#]", "Hello, I am Scribe.!",
      ])
    container.moveDown()
    container.expectState(
      &renderer,
      expected: [
        "Zane was here :1", "[Job running: ready]", "Nested[text: Hello#]", "Hello, I am Scribe.!",
      ])
    container.action(.lowercaseI)
    container.expectState(
      &renderer,
      expected: [
        "Zane was here :1", "[Job running: running]", "Nested[text: running]",
        "Hello, I am Scribe.!",
      ])
    try await Task.sleep(for: .seconds(0.5))
    container.expectState(
      &renderer,
      expected: [
        "Zane was here :1", "[Job running: running]", "Nested[text: running]",
        "Hello, I am Scribe.!",
      ])
    try await Task.sleep(for: .seconds(1))
    container.expectState(
      &renderer,
      expected: [
        "Zane was here :1", "[Job running: ready]", "Nested[text: ready]", "Hello, I am Scribe.!",
      ])
    container.moveUp()
    container.expectState(
      &renderer,
      expected: [
        "[Zane was here :1]", "Job running: ready", "Nested[text: ready]", "Hello, I am Scribe.!",
      ])

  }

  @Test func selectAll() async throws {
    let block = All()
    var container = BlockContainer(block)
    var renderer = TestRenderer()
    container.expectState(&renderer, expected: ["[A]", "[Button]", "[Here]", "[Was]", "[Zane]"])
    // Move in
    container.moveIn()

    container.moveIn()
    container.expectState(&renderer, expected: ["[Button]", "A", "Zane", "Was", "Here"])
    container.action(.lowercaseI)
    container.expectState(&renderer, expected: ["[Button]", "B", "Zane", "Was", "Here"])
  }

  @Test func selectOptionalBlock() async throws {
    let block = OptionalBlock()
    var container = BlockContainer(block)
    var renderer = TestRenderer()
    container.expectState(
      &renderer, expected: ["[Hello]", "[OptionalBlock(idk: Optional(\"Hello\"))]"])
  }

  @Test func selectBasicTupleText() async throws {
    let block = BasicTupleText()
    var container = BlockContainer(block)
    var renderer = TestRenderer()
    container.expectState(&renderer, expected: ["[Hello]", "[Zane]"])
  }

  @Test func selectBasicTupleTextMoveIn() async throws {
    let block = BasicTupleText()
    var container = BlockContainer(block)
    var renderer = TestRenderer()
    container.expectState(&renderer, expected: ["[Hello]", "[Zane]"])
    container.moveIn()
    container.moveIn()
    container.expectState(&renderer, expected: ["[Hello]", "Zane"])
  }

  @Test func selectBasicTupleTextMoveInAndOut() async throws {
    let block = BasicTupleText()
    var container = BlockContainer(block)
    var renderer = TestRenderer()
    container.expectState(&renderer, expected: ["[Hello]", "[Zane]"])
    container.moveIn()
    container.moveIn()
    container.expectState(&renderer, expected: ["[Hello]", "Zane"])
    container.moveOut()
    container.expectState(&renderer, expected: ["[Hello]", "[Zane]"])
  }

  @Test func selectBasicTupleTextMoveInDownOut() async throws {
    let block = BasicTupleText()
    var container = BlockContainer(block)
    var renderer = TestRenderer()
    container.expectState(&renderer, expected: ["[Hello]", "[Zane]"])
    container.moveIn()
    container.moveIn()
    container.expectState(&renderer, expected: ["[Hello]", "Zane"])
    container.moveDown()
    container.expectState(&renderer, expected: ["Hello", "[Zane]"])
    container.moveOut()
    container.expectState(&renderer, expected: ["[Hello]", "[Zane]"])
  }

  @Test func selectBasicTupleTextMoveInDownUpOut() async throws {
    let block = BasicTupleText()
    var container = BlockContainer(block)
    var renderer = TestRenderer()
    container.expectState(&renderer, expected: ["[Hello]", "[Zane]"])
    container.moveIn()
    container.moveIn()
    container.expectState(&renderer, expected: ["[Hello]", "Zane"])
    container.moveDown()
    container.expectState(&renderer, expected: ["Hello", "[Zane]"])
    container.moveUp()
    container.expectState(&renderer, expected: ["[Hello]", "Zane"])
    container.moveOut()
    container.expectState(&renderer, expected: ["[Hello]", "[Zane]"])
  }

  @Test func selectSelectionBlock() async throws {
    let block = SelectionBlock()
    var container = BlockContainer(block)
    var renderer = TestRenderer()
    container.expectState(
      &renderer, expected: ["[0]", "[1]", "[2]", "[Hello]", "[Zane]", "[here]", "[was]"])

    // Move in
    container.moveIn()
    container.expectState(
      &renderer, expected: ["[0]", "[1]", "[2]", "[Hello]", "[Zane]", "[here]", "[was]"])

    // Move in
    container.moveIn()
    container.expectState(&renderer, expected: ["0", "1", "2", "Zane", "[Hello]", "here", "was"])

    // Move in
    container.moveIn()
    container.expectState(&renderer, expected: ["0", "1", "2", "Zane", "[Hello]", "here", "was"])

    // Move in
    container.moveIn()
    container.expectState(&renderer, expected: ["0", "1", "2", "Zane", "[Hello]", "here", "was"])

    // Move Down
    container.moveDown()
    container.expectState(&renderer, expected: ["0", "1", "2", "[Zane]", "Hello", "here", "was"])

    // Move Up
    container.moveUp()
    container.expectState(&renderer, expected: ["0", "1", "2", "Zane", "[Hello]", "here", "was"])

    // Move Down
    container.moveDown()
    container.expectState(&renderer, expected: ["0", "1", "2", "[Zane]", "Hello", "here", "was"])

    // Move Down
    container.moveDown()
    container.expectState(&renderer, expected: ["0", "1", "2", "Zane", "Hello", "here", "[was]"])

    // Move Down
    container.moveDown()
    container.expectState(&renderer, expected: ["0", "1", "2", "Zane", "Hello", "[here]", "was"])

    // Move Down
    container.moveDown()
    container.expectState(
      &renderer, expected: ["[0]", "[1]", "[2]", "Zane", "Hello", "here", "was"])

    // Move Down
    container.moveDown()
    container.expectState(&renderer, expected: ["[0]", "1", "2", "Zane", "Hello", "here", "was"])

    // Move Down
    container.moveDown()
    container.expectState(&renderer, expected: ["0", "[1]", "2", "Zane", "Hello", "here", "was"])

    // Move Down
    container.moveDown()
    container.expectState(&renderer, expected: ["0", "1", "[2]", "Zane", "Hello", "here", "was"])

    // Move Down
    container.moveDown()
    container.expectState(&renderer, expected: ["0", "1", "[2]", "Zane", "Hello", "here", "was"])

    // Move Down
    container.moveDown()
    container.expectState(&renderer, expected: ["0", "1", "[2]", "Zane", "Hello", "here", "was"])

    // Move Up
    container.moveUp()
    container.expectState(&renderer, expected: ["0", "[1]", "2", "Zane", "Hello", "here", "was"])

    // Move out
    container.moveOut()
    container.expectState(
      &renderer, expected: ["[0]", "[1]", "[2]", "Zane", "Hello", "here", "was"])

    // Move out
    container.moveOut()
    container.expectState(
      &renderer, expected: ["[0]", "[1]", "[2]", "[Hello]", "[Zane]", "[here]", "[was]"])

    // Move out
    container.moveOut()
    container.expectState(
      &renderer, expected: ["[0]", "[1]", "[2]", "[Hello]", "[Zane]", "[here]", "[was]"])

    // Move out
    container.moveOut()
    container.expectState(
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
    container.moveIn()
    container.expectState(&renderer, expected: ["[ready]"])

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

  mutating func expectState(_ renderer: inout TestRenderer, expected: [String]) {
    self.observe(with: &renderer)
    let output = renderer.previousWalker.textObjects.map { $0.value }
    #expect(output.sorted() == expected.sorted())
  }

  // Helper for creating expected arrays
  mutating func printState(_ renderer: inout TestRenderer) {
    self.observe(with: &renderer)
    let output = renderer.previousWalker.textObjects.map { $0.value }
    print(output)
  }
}
