import Foundation

/// Produces a bounded depth-first preorder traversal. Keeping this independent
/// of AXUIElement lets us test the ordering and limits without Accessibility
/// permission or a running GUI application.
func depthFirstPreorder<Element>(
  root: Element,
  maxDepth: Int,
  maxCount: Int,
  maxChildren: Int,
  children: (Element) -> [Element]
) -> [(element: Element, depth: Int)] {
  guard maxCount > 0 else { return [] }
  var output: [(element: Element, depth: Int)] = []

  func visit(_ element: Element, depth: Int) {
    guard output.count < maxCount else { return }
    output.append((element, depth))
    guard depth < maxDepth else { return }
    for child in children(element).prefix(max(0, maxChildren)) {
      visit(child, depth: depth + 1)
      if output.count >= maxCount { break }
    }
  }

  visit(root, depth: 0)
  return output
}

/// Maps the agent-facing action vocabulary to native Accessibility action
/// names. Attribute writes such as focus and set_text are intentionally absent.
func semanticAccessibilityActionName(for action: String) -> String? {
  switch action {
  case "press": return "AXPress"
  case "confirm": return "AXConfirm"
  case "show_menu": return "AXShowMenu"
  case "scroll_to_visible": return "AXScrollToVisible"
  case "increment": return "AXIncrement"
  case "decrement": return "AXDecrement"
  case "scroll_down": return "AXScrollDownByPage"
  case "scroll_up": return "AXScrollUpByPage"
  default: return nil
  }
}
