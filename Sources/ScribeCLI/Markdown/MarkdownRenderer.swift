import SlateCore

public protocol MarkdownRenderer: Sendable {

  func render(text: String, baseFG: TerminalRGB, baseBold: Bool, theme: MarkdownTheme) -> [TLine]

  func renderStreaming(text: String, baseFG: TerminalRGB, baseBold: Bool, theme: MarkdownTheme) -> [TLine]
}

extension MarkdownRenderer {

  public func render(text: String, baseFG: TerminalRGB, baseBold: Bool) -> [TLine] {
    render(text: text, baseFG: baseFG, baseBold: baseBold, theme: .vibrant)
  }

  public func renderStreaming(text: String, baseFG: TerminalRGB, baseBold: Bool, theme: MarkdownTheme) -> [TLine] {
    render(text: text, baseFG: baseFG, baseBold: baseBold, theme: theme)
  }
}
