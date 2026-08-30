#if canImport(AppKit)
import CoreGraphics
import Testing

@testable import ScribeComputerUse

@Suite
struct ObservationFilteringTests {
  private let viewport = CGRect(x: 0, y: 0, width: 1_000, height: 800)

  @Test func queryAndRoleFiltersAreCaseInsensitive() {
    let nodes = [
      node(ref: "@e1", role: "AXLink", title: "Zillow Rentals", actions: ["AXPress"]),
      node(ref: "@e2", role: "AXButton", title: "Search", actions: ["AXPress"]),
    ]
    let options = UIObservationOptions(
      roles: ["link"], query: "zILLoW", maximumNodeCount: 20)

    let page = observationPage(nodes: nodes, options: options, windowFrame: viewport, offset: 0)

    #expect(page.nodes.map(\.ref) == ["@e1"])
    #expect(page.nextOffset == nil)
  }

  @Test func interactiveAndViewportFiltersExcludeUnusableNodes() {
    let nodes = [
      node(ref: "@e1", role: "AXLink", title: "Visible", actions: ["AXPress"]),
      node(
        ref: "@e2", role: "AXLink", title: "Offscreen", frame: CGRect(x: 2_000, y: 0, width: 50, height: 20),
        actions: ["AXPress"]),
      node(ref: "@e3", role: "AXStaticText", title: "Not interactive"),
      node(ref: "@e4", role: "AXButton", title: "Disabled", actions: ["AXPress"], enabled: false),
    ]
    let options = UIObservationOptions(
      viewportOnly: true, interactiveOnly: true, maximumNodeCount: 20)

    let page = observationPage(nodes: nodes, options: options, windowFrame: viewport, offset: 0)

    #expect(page.nodes.map(\.ref) == ["@e1"])
  }

  @Test func paginationIsDeterministicAndReportsContinuation() {
    let nodes = (1...5).map {
      node(ref: "@e\($0)", role: "AXLink", title: "Result \($0)", actions: ["AXPress"])
    }
    let options = UIObservationOptions(interactiveOnly: true, maximumNodeCount: 2)

    let first = observationPage(nodes: nodes, options: options, windowFrame: viewport, offset: 0)
    let second = observationPage(
      nodes: nodes, options: options, windowFrame: viewport, offset: first.nextOffset ?? 0)
    let third = observationPage(
      nodes: nodes, options: options, windowFrame: viewport, offset: second.nextOffset ?? 0)

    #expect(first.nodes.map(\.ref) == ["@e1", "@e2"])
    #expect(first.nextOffset == 2)
    #expect(first.matchedNodeCount == 5)
    #expect(second.nodes.map(\.ref) == ["@e3", "@e4"])
    #expect(second.nextOffset == 4)
    #expect(third.nodes.map(\.ref) == ["@e5"])
    #expect(third.nextOffset == nil)
  }

  @Test func visibleOnlyExcludesHiddenNodes() {
    let nodes = [
      node(ref: "@e1", role: "AXLink", title: "Visible", actions: ["AXPress"]),
      node(ref: "@e2", role: "AXLink", title: "Hidden", actions: ["AXPress"], hidden: true),
    ]
    let options = UIObservationOptions(visibleOnly: true, maximumNodeCount: 20)

    let page = observationPage(nodes: nodes, options: options, windowFrame: viewport, offset: 0)

    #expect(page.nodes.map(\.ref) == ["@e1"])
  }

  private func node(
    ref: String,
    role: String,
    title: String,
    frame: CGRect = CGRect(x: 10, y: 10, width: 100, height: 30),
    actions: [String] = [],
    hidden: Bool = false,
    enabled: Bool = true
  ) -> UIOutlineNode {
    UIOutlineNode(
      ref: ref,
      role: role,
      title: title,
      value: "",
      nodeDescription: "",
      url: "",
      frame: frame,
      actions: actions,
      depth: 1,
      hidden: hidden,
      enabled: enabled,
      focused: false,
      selected: false)
  }
}
#endif
