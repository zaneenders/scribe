import Chroma
import HeadlessBackend
import Testing

@testable import ScribeBlocks

@MainActor
struct ThemeTests {
  @Test func scribeBlockAdoptsInheritedChromaTheme() {
    let theme = ChromaTheme.dark.accentColor(Color(r: 0.8, g: 0.4, b: 0.7, a: 1))
    let renderer = HeadlessRenderer(size: Size(width: 800, height: 600))
    defer { renderer.close() }
    renderer.content = ScribeBlock(workspace: ScribeWorkspace()).chromaTheme(theme)

    let frame = renderer.render()
    #expect(
      frame.commands.contains(.fillRect(rect: Rect(x: 0, y: 0, width: 800, height: 600), color: theme.background)))
    #expect(hasText("Scribe", color: theme.foreground, in: frame.commands))
    #expect(hasFill(theme.surface, in: frame.commands))
  }

  @Test func localChromeUsesInheritedPalette() {
    var theme = ChromaTheme.dark
    theme.background = Color(r: 0.11, g: 0.12, b: 0.13, a: 1)
    theme.elevatedSurface = Color(r: 0.21, g: 0.22, b: 0.23, a: 1)
    theme.textField.idleBackground = Color(r: 0.31, g: 0.32, b: 0.33, a: 1)

    let local = MacTheme(chromaTheme: theme)
    #expect(local.composerBackground == theme.elevatedSurface)
    #expect(local.statusBackground == theme.elevatedSurface)
    #expect(local.sidebarBackground == theme.elevatedSurface)
    #expect(local.userBubbleBackground == theme.textField.idleBackground)
  }

  @Test func localWorkspaceUsesCompactColorfulChrome() {
    var theme = ChromaTheme.dark
    theme.elevatedSurface = Color(r: 0.1, g: 0.07, b: 0.12, a: 1)
    theme.positive = Color(r: 0.6, g: 0.85, b: 0.75, a: 1)
    theme.negative = Color(r: 0.9, g: 0.65, b: 0.75, a: 1)
    theme.textField.editingBorder = Color(r: 0.55, g: 0.75, b: 0.9, a: 1)
    let local = MacTheme(chromaTheme: theme)
    #expect(local.sidebarWidth == 260)
    #expect(local.smallScale == 0.55)
    #expect(local.green == theme.positive)
    #expect(local.red == theme.negative)
    #expect(local.blue == theme.textField.editingBorder)
    #expect(local.composerBackground == theme.elevatedSurface)
  }

  @Test func composerUsesInheritedTextFieldColors() {
    var theme = ChromaTheme.dark
    theme.textField = TextFieldStyle(
      idleBackground: Color(r: 0.2, g: 0.1, b: 0.3, a: 1),
      hoveredBackground: Color(r: 0.25, g: 0.15, b: 0.35, a: 1),
      editingBackground: Color(r: 0.3, g: 0.2, b: 0.4, a: 1),
      foreground: theme.foreground,
      placeholder: Color(r: 0.7, g: 0.5, b: 0.8, a: 1),
      caret: theme.accent, border: theme.border, editingBorder: theme.accent)
    let renderer = HeadlessRenderer(size: Size(width: 400, height: 100))
    defer { renderer.close() }
    renderer.content = GrowingTextField(
      "Message Scribe", fontScale: 0.85, text: { "" },
      onChange: { _ in }, onNewline: {}
    ).chromaTheme(theme)

    let frame = renderer.render()
    #expect(hasFill(theme.textField.hoveredBackground, in: frame.commands))
    #expect(hasText("Message Scribe", color: theme.textField.placeholder, in: frame.commands))
  }

  private func hasText(_ text: String, color: Color, in commands: [DrawCommand]) -> Bool {
    commands.contains { command in
      guard case .text(_, let value, let foreground, _) = command else { return false }
      return value == text && foreground == color
    }
  }

  private func hasFill(_ color: Color, in commands: [DrawCommand]) -> Bool {
    commands.contains { command in
      switch command {
      case .fillRect(_, let fill), .fillRoundedRect(_, _, let fill): fill == color
      default: false
      }
    }
  }
}
