#if canImport(AppKit)
import Foundation

struct UIObservationOptions: Sendable {
  var visibleOnly = false
  var viewportOnly = false
  var interactiveOnly = false
  var roles: Set<String> = []
  var query: String?
  var maximumDepth = 12
  var maximumNodeCount = 200

  func matches(_ node: UIOutlineNode, windowFrame: CGRect) -> Bool {
    if node.depth > maximumDepth { return false }
    if visibleOnly && !node.isVisible(in: windowFrame) { return false }
    if viewportOnly && !node.isInViewport(windowFrame) { return false }
    if interactiveOnly && !node.isInteractive { return false }
    if !roles.isEmpty && !roles.contains(node.normalizedRole) { return false }
    if let query, !query.isEmpty {
      let haystack = [node.title, node.value, node.nodeDescription, node.url]
        .joined(separator: " ").lowercased()
      if !haystack.contains(query.lowercased()) { return false }
    }
    return true
  }
}

struct UIOutlineNode {
  let ref: String
  let role: String
  let title: String
  let value: String
  let nodeDescription: String
  let url: String
  let frame: CGRect?
  let actions: [String]
  let depth: Int
  let hidden: Bool
  let enabled: Bool
  let focused: Bool
  let selected: Bool

  var normalizedRole: String {
    role.hasPrefix("AX") ? String(role.dropFirst(2)).lowercased() : role.lowercased()
  }

  var isInteractive: Bool {
    if !enabled { return false }
    if !actions.isEmpty { return true }
    return [
      "button", "checkbox", "combobox", "link", "menuitem", "popupbutton",
      "radiobutton", "searchfield", "slider", "textfield",
    ].contains(normalizedRole)
  }

  func isInViewport(_ viewport: CGRect) -> Bool {
    guard let frame, !frame.isEmpty else { return false }
    return frame.intersects(viewport)
  }

  func isVisible(in viewport: CGRect) -> Bool {
    !hidden && isInViewport(viewport)
  }
}

struct UIObservationPage {
  let nodes: [UIOutlineNode]
  let nextOffset: Int?
  let matchedNodeCount: Int
}

func observationPage(
  nodes: [UIOutlineNode],
  options: UIObservationOptions,
  windowFrame: CGRect,
  offset: Int
) -> UIObservationPage {
  let matches = nodes.filter { options.matches($0, windowFrame: windowFrame) }
  let safeOffset = min(max(0, offset), matches.count)
  let end = min(matches.count, safeOffset + max(1, options.maximumNodeCount))
  return UIObservationPage(
    nodes: Array(matches[safeOffset..<end]),
    nextOffset: end < matches.count ? end : nil,
    matchedNodeCount: matches.count)
}
#endif
