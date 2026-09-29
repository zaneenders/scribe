import Chroma
import HeadlessBackend
import Testing

@testable import ScribeBlocks

@MainActor
struct ProgressIndicatorTests {
  @Test func requestsAnimationOnlyWhilePresent() {
    let renderer = HeadlessHost()
    defer { renderer.close() }
    renderer.content = ProgressIndicator(color: .white)
    renderer.render()
    #expect(renderer.needsAnimationFrame)
    renderer.render()
    #expect(renderer.needsAnimationFrame)

    renderer.content = Text("Ready")
    renderer.render()
    #expect(!renderer.needsAnimationFrame)
  }
}
