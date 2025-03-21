import Testing

@testable import Demo
@testable import Scribe

@MainActor  // UI Block test run on main thread.
@Suite("Render Tests")
struct RenderTests {

  /*
  Test displays blocks different depending on if a parent block is selected.
  */
  @Test func testAllBlock() async throws {
    let block = All()
    var container = BlockContainer(block)
    var renderer = TestRenderer()
    container.observe(with: &renderer)
    var output = renderer.previousVisitor.textObjects.map { $0.value }
    var expected = ["[A]", "[Was]", "[Here]", "[Button]", "[Zane]"]
    #expect(output.sorted() == expected.sorted())
    container.action(.lowercaseL)
    container.observe(with: &renderer)
    output = renderer.previousVisitor.textObjects.map { $0.value }
    expected = ["[A]", "[Was]", "[Here]", "[Button]", "[Zane]"]
    #expect(output.sorted() == expected.sorted())
    container.action(.lowercaseL)
    container.observe(with: &renderer)
    output = renderer.previousVisitor.textObjects.map { $0.value }
    expected = ["Here", "Zane", "[Button]", "A", "Was"]
    #expect(output.sorted() == expected.sorted())
    container.action(.lowercaseI)
    container.observe(with: &renderer)
    output = renderer.previousVisitor.textObjects.map { $0.value }
    expected = ["Here", "Zane", "[Button]", "B", "Was"]
    #expect(output.sorted() == expected.sorted())
  }
}
