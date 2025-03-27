import Testing

@testable import Demo
@testable import Scribe

@MainActor  // UI Block test run on main thread.
@Suite("Layer Tests")
struct LayerTests {
  @Test func layerEntry() async throws {
    let block = Entry()
    let l1 = block.toL1Element()
    let l2 = block.optimizeTree()
    print(l2)
    let l1Tree: L1Element = .group([
      L1Element.group([
        L1Element.wrapped(L1Element.text("Hello, I am Scribe."), key: "i", action: Optional({})),
        L1Element.wrapped(L1Element.text("Zane was here :0"), key: "e", action: Optional({})),
        L1Element.wrapped(L1Element.text("Job running: ready"), key: "i", action: Optional({})),
        L1Element.group([L1Element.text("Nested[text: Hello]")]),
      ])
    ])
    let expected: L2Element = .group(
      [
        L2Element.group(
          [
            L2Element.group(
              [L2Element.text("Hello, I am Scribe.", nil)],
              Optional(L2Binding(key: "i", action: {}))),
            L2Element.group(
              [L2Element.text("Zane was here :0", nil)], Optional(L2Binding(key: "e", action: {}))),
            L2Element.group(
              [L2Element.text("Job running: ready", nil)], Optional(L2Binding(key: "i", action: {}))
            ), L2Element.group([L2Element.text("Nested[text: Hello]", nil)], nil),
          ], nil)
      ], nil)
  }
}
