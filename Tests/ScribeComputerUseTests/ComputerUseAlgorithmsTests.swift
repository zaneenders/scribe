@testable import ScribeComputerUse
import Testing

@Suite
struct ComputerUseAlgorithmsTests {
  private struct Node: Sendable {
    let name: String
    let children: [Node]

    init(_ name: String, _ children: [Node] = []) {
      self.name = name
      self.children = children
    }
  }

  @Test func traversalIsDepthFirstPreorderAndPreservesDepth() {
    let root = Node("root", [
      Node("toolbar", [Node("back"), Node("address")]),
      Node("content", [Node("filter", [Node("price")])]),
    ])

    let result = depthFirstPreorder(
      root: root, maxDepth: 12, maxCount: 600, maxChildren: 200,
      children: \.children)

    #expect(result.map { $0.element.name } == ["root", "toolbar", "back", "address", "content", "filter", "price"])
    #expect(result.map(\.depth) == [0, 1, 2, 2, 1, 2, 3])
  }

  @Test func traversalHonorsNodeLimit() {
    let root = Node("root", [Node("one"), Node("two"), Node("three")])
    let result = depthFirstPreorder(
      root: root, maxDepth: 12, maxCount: 3, maxChildren: 200,
      children: \.children)

    #expect(result.map { $0.element.name } == ["root", "one", "two"])
  }

  @Test func traversalHonorsDepthLimit() {
    let root = Node("root", [Node("child", [Node("grandchild")])])
    let result = depthFirstPreorder(
      root: root, maxDepth: 1, maxCount: 600, maxChildren: 200,
      children: \.children)

    #expect(result.map { $0.element.name } == ["root", "child"])
  }

  @Test func traversalHonorsPerNodeChildLimit() {
    let root = Node("root", [Node("one"), Node("two"), Node("three")])
    let result = depthFirstPreorder(
      root: root, maxDepth: 12, maxCount: 600, maxChildren: 2,
      children: \.children)

    #expect(result.map { $0.element.name } == ["root", "one", "two"])
  }

  @Test(arguments: [
    ("press", "AXPress"),
    ("confirm", "AXConfirm"),
    ("show_menu", "AXShowMenu"),
    ("scroll_to_visible", "AXScrollToVisible"),
    ("increment", "AXIncrement"),
    ("decrement", "AXDecrement"),
    ("scroll_down", "AXScrollDownByPage"),
    ("scroll_up", "AXScrollUpByPage"),
  ])
  func semanticActionMapping(action: String, expected: String) {
    #expect(semanticAccessibilityActionName(for: action) == expected)
  }

  @Test func attributeAndUnknownActionsHaveNoSemanticMapping() {
    #expect(semanticAccessibilityActionName(for: "focus") == nil)
    #expect(semanticAccessibilityActionName(for: "set_text") == nil)
    #expect(semanticAccessibilityActionName(for: "launch_missiles") == nil)
  }
}
