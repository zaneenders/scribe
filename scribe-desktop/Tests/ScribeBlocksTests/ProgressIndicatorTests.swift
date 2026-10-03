import Chroma
import ChromaTesting
import Testing

@testable import ScribeBlocks

@MainActor
struct ProgressIndicatorTests {
  @Test func staticIndicatorDoesNotScheduleAnimation() {
    let renderer = HeadlessHost()
    defer { renderer.close() }
    renderer.content = ProgressIndicator(color: .white)
    renderer.render()
    #expect(renderer.renderIfNeeded() == nil)
    renderer.render()
    #expect(renderer.renderIfNeeded() == nil)

    renderer.content = Text("Ready")
    renderer.render()
    #expect(renderer.renderIfNeeded() == nil)
  }
}
