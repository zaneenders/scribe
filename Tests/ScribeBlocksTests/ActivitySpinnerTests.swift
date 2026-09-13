import Chroma
import HeadlessBackend
import Testing

@testable import ScribeBlocks

@MainActor
struct ActivitySpinnerTests {
  @Test func requestsAnimationOnlyWhilePresent() {
    let renderer = HeadlessRenderer()
    defer { renderer.close() }
    renderer.content = ActivitySpinner(color: .white)
    renderer.render()
    #expect(renderer.needsAnimationFrame)
    renderer.render()
    #expect(renderer.needsAnimationFrame)

    renderer.content = Text("Ready")
    renderer.render()
    #expect(!renderer.needsAnimationFrame)
  }
}
