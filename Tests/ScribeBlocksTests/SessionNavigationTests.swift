import Chroma
import HeadlessBackend
import ScribeBlocks
import Testing

@MainActor
struct SessionNavigationTests {
  @Test func groupActionsAreIndependent() {
    var toggles = 0
    var creations = 0
    let renderer = HeadlessRenderer(size: Size(width: 400, height: 80))
    defer { renderer.close() }
    renderer.content = ScribeSessionGroup(
      id: "test-group", title: "Project", count: 3, isCollapsed: true,
      style: ScribeSessionGroupStyle(
        foreground: .white, hoveredForeground: .white, count: .white,
        newSession: .white, hoverBackground: .clear, fontScale: 1),
      onToggle: { toggles += 1 }, onNewSession: { creations += 1 })
    click("+", in: renderer)
    #expect(creations == 1)
    #expect(toggles == 0)
    click(">", in: renderer)
    #expect(toggles == 1)
    #expect(creations == 1)
  }

  @Test func rowUsesSuppliedDataStyleAndSelectionAction() {
    var selections = 0
    let color = Color(r: 0.7, g: 0.2, b: 0.4, a: 1)
    let renderer = HeadlessRenderer(size: Size(width: 400, height: 80))
    defer { renderer.close() }
    renderer.content = ScribeSessionRow(
      id: "test-session", title: "Planning", subtitle: "model", isSelected: true,
      style: ScribeSessionRowStyle(
        foreground: .white, secondaryForeground: .white, selectedForeground: color,
        activity: .white, selection: .clear, hover: .clear, border: color, fontScale: 1),
      onSelect: { selections += 1 })
    let frame = renderer.render()
    #expect(frame.commands.contains {
      if case .text(_, "Planning", let foreground, _) = $0 { return foreground == color }
      return false
    })
    click("Planning", in: renderer)
    #expect(selections == 1)
  }

  private func click(_ text: String, in renderer: HeadlessRenderer) {
    let frame = renderer.render()
    guard let position = frame.commands.compactMap({ command -> Point? in
      if case .text(let position, let value, _, _) = command, value == text { return position }
      return nil
    }).first else {
      Issue.record("Missing control: \(text)")
      return
    }
    let point = Point(x: position.x + 3, y: position.y + 3)
    renderer.render(input: InputState(pointerPosition: point, pointerPressed: true))
    renderer.render(input: InputState(pointerPosition: point, pointerReleased: true))
    renderer.render()
  }
}
