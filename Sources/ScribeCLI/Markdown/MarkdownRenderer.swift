import SlateCore

/// Renders markdown text into styled terminal lines.
///
/// Implementations are expected to be stateless and `Sendable` so they can be
/// stored in the transcript sink and invoked on every SSE chunk.
public protocol MarkdownRenderer: Sendable {
  /// Parse `text` as markdown and emit styled terminal lines.
  /// - Parameters:
  ///   - text: The complete markdown buffer to parse.
  ///   - baseFG: Default foreground color for unstyled text.
  ///   - baseBold: Default bold flag for unstyled text.
  ///   - theme: Color theme for markdown elements (e.g. `.vibrant` or `.grayscale`).
  /// - Returns: An array of logical lines. The caller is responsible for
  ///   word-wrapping these lines to the terminal width.
  func render(text: String, baseFG: TerminalRGB, baseBold: Bool, theme: MarkdownTheme) -> [TLine]

  /// Fast path for streaming: renders only inline markdown patterns
  /// (`**bold**`, `*italic*`, `` `code` ``) without block-level parsing.
  ///
  /// Called on every SSE chunk during streaming.  The full `render` is invoked
  /// once at finalize to apply block-level formatting (headings, code blocks, etc.).
  ///
  /// Default implementation falls back to `render`.
  func renderStreaming(text: String, baseFG: TerminalRGB, baseBold: Bool, theme: MarkdownTheme) -> [TLine]
}

extension MarkdownRenderer {
  /// Default implementation using the vibrant theme.
  public func render(text: String, baseFG: TerminalRGB, baseBold: Bool) -> [TLine] {
    render(text: text, baseFG: baseFG, baseBold: baseBold, theme: .vibrant)
  }

  public func renderStreaming(text: String, baseFG: TerminalRGB, baseBold: Bool, theme: MarkdownTheme) -> [TLine] {
    render(text: text, baseFG: baseFG, baseBold: baseBold, theme: theme)
  }
}
