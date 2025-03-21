import Testing

@testable import Demo
@testable import Scribe

@MainActor  // UI Block test run on main thread.
@Suite("Selection Tests")
struct SelectionTests {

  @Test func select() async throws {
    let block = SelectionBlock()
    var container = BlockContainer(block)
    var renderer = TestRenderer()
    container.observe(with: &renderer)
    var output = renderer.previousVisitor.textObjects.map { $0.value }
    var expected = ["[0]", "[1]", "[2]", "[Hello]", "[Zane]", "[here]", "[was]"]
    #expect(output.sorted() == expected.sorted())

    // Move in
    container.action(.lowercaseL)
    container.observe(with: &renderer)
    output = renderer.previousVisitor.textObjects.map { $0.value }
    expected = ["[0]", "[1]", "[2]", "[Hello]", "[Zane]", "[here]", "[was]"]
    #expect(output.sorted() == expected.sorted())

    // Move in
    container.action(.lowercaseL)
    container.observe(with: &renderer)
    output = renderer.previousVisitor.textObjects.map { $0.value }
    expected = ["0", "1", "2", "Zane", "[Hello]", "here", "was"]
    #expect(output.sorted() == expected.sorted())

    // Move in
    container.action(.lowercaseL)
    container.observe(with: &renderer)
    output = renderer.previousVisitor.textObjects.map { $0.value }
    expected = ["0", "1", "2", "Zane", "[Hello]", "here", "was"]
    #expect(output.sorted() == expected.sorted())

    // Move in
    container.action(.lowercaseL)
    container.observe(with: &renderer)
    output = renderer.previousVisitor.textObjects.map { $0.value }
    expected = ["0", "1", "2", "Zane", "[Hello]", "here", "was"]
    #expect(output.sorted() == expected.sorted())

    // Move Down
    container.action(.lowercaseJ)
    container.observe(with: &renderer)
    output = renderer.previousVisitor.textObjects.map { $0.value }
    expected = ["0", "1", "2", "[Zane]", "Hello", "here", "was"]
    #expect(output.sorted() == expected.sorted())

    // Move Up
    container.action(.lowercaseF)
    container.observe(with: &renderer)
    output = renderer.previousVisitor.textObjects.map { $0.value }
    expected = ["0", "1", "2", "Zane", "[Hello]", "here", "was"]
    #expect(output.sorted() == expected.sorted())

    // Move Down
    container.action(.lowercaseJ)
    container.observe(with: &renderer)
    output = renderer.previousVisitor.textObjects.map { $0.value }
    expected = ["0", "1", "2", "[Zane]", "Hello", "here", "was"]
    #expect(output.sorted() == expected.sorted())

    // Move Down
    container.action(.lowercaseJ)
    container.observe(with: &renderer)
    output = renderer.previousVisitor.textObjects.map { $0.value }
    expected = ["0", "1", "2", "Zane", "Hello", "here", "[was]"]
    #expect(output.sorted() == expected.sorted())

    // Move Down
    container.action(.lowercaseJ)
    container.observe(with: &renderer)
    output = renderer.previousVisitor.textObjects.map { $0.value }
    expected = ["0", "1", "2", "Zane", "Hello", "[here]", "was"]
    #expect(output.sorted() == expected.sorted())

    // Move Down
    container.action(.lowercaseJ)
    container.observe(with: &renderer)
    output = renderer.previousVisitor.textObjects.map { $0.value }
    expected = ["[0]", "[1]", "[2]", "Zane", "Hello", "here", "was"]
    #expect(output.sorted() == expected.sorted())

    // Move Down
    container.action(.lowercaseJ)
    container.observe(with: &renderer)
    output = renderer.previousVisitor.textObjects.map { $0.value }
    expected = ["[0]", "1", "2", "Zane", "Hello", "here", "was"]
    #expect(output.sorted() == expected.sorted())

    // Move Down
    container.action(.lowercaseJ)
    container.observe(with: &renderer)
    output = renderer.previousVisitor.textObjects.map { $0.value }
    expected = ["0", "[1]", "2", "Zane", "Hello", "here", "was"]
    #expect(output.sorted() == expected.sorted())

    // Move Down
    container.action(.lowercaseJ)
    container.observe(with: &renderer)
    output = renderer.previousVisitor.textObjects.map { $0.value }
    expected = ["0", "1", "[2]", "Zane", "Hello", "here", "was"]
    #expect(output.sorted() == expected.sorted())

    // Move Down
    container.action(.lowercaseJ)
    container.observe(with: &renderer)
    output = renderer.previousVisitor.textObjects.map { $0.value }
    expected = ["0", "1", "[2]", "Zane", "Hello", "here", "was"]
    #expect(output.sorted() == expected.sorted())

    // Move Down
    container.action(.lowercaseJ)
    container.observe(with: &renderer)
    output = renderer.previousVisitor.textObjects.map { $0.value }
    expected = ["0", "1", "[2]", "Zane", "Hello", "here", "was"]
    #expect(output.sorted() == expected.sorted())

    // Move out
    container.action(.lowercaseS)
    container.observe(with: &renderer)
    output = renderer.previousVisitor.textObjects.map { $0.value }
    expected = ["[0]", "[1]", "[2]", "Zane", "Hello", "here", "was"]
    #expect(output.sorted() == expected.sorted())

    // Move out
    container.action(.lowercaseS)
    container.observe(with: &renderer)
    output = renderer.previousVisitor.textObjects.map { $0.value }
    expected = ["[0]", "[1]", "[2]", "[Hello]", "[Zane]", "[here]", "[was]"]
    #expect(output.sorted() == expected.sorted())

    // Move out
    container.action(.lowercaseS)
    container.observe(with: &renderer)
    output = renderer.previousVisitor.textObjects.map { $0.value }
    expected = ["[0]", "[1]", "[2]", "[Hello]", "[Zane]", "[here]", "[was]"]
    #expect(output.sorted() == expected.sorted())

    // Move out
    container.action(.lowercaseS)
    container.observe(with: &renderer)
    output = renderer.previousVisitor.textObjects.map { $0.value }
    expected = ["[0]", "[1]", "[2]", "[Hello]", "[Zane]", "[here]", "[was]"]
    #expect(output.sorted() == expected.sorted())
  }
}
