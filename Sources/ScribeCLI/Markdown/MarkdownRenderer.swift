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
  /// - Returns: An array of logical lines. The caller is responsible for
  ///   word-wrapping these lines to the terminal width.
  func render(text: String, baseFG: TerminalRGB, baseBold: Bool) -> [TLine]
}
