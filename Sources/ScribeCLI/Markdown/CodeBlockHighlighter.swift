import SlateCore

/// Highlights code inside fenced code blocks.
///
/// The renderer calls this for every ``CodeBlock`` it encounters.  If no
/// highlighter is supplied the renderer falls back to a single flat colour.
public protocol CodeBlockHighlighter: Sendable {
  /// Highlight raw code and return one styled line per logical source line.
  /// - Parameters:
  ///   - code: The raw code text (may contain `\n`).
  ///   - language: The language identifier from the opening fence (e.g. `swift`), or `nil`.
  /// - Returns: One ``TLine`` per logical line of the code block.
  func highlight(code: String, language: String?) -> [TLine]
}

/// Default highlighter that applies a flat colour to every code line.
public struct PlainCodeBlockHighlighter: CodeBlockHighlighter {
  public init() {}

  public func highlight(code: String, language: String?) -> [TLine] {
    code.split(separator: "\n", omittingEmptySubsequences: false).map { line in
      TLine(
        spans: [
          StyledSpan(
            fg: ScribePalette.markdownCodeBlock,
            bg: ScribePalette.black,
            bold: false,
            text: String(line))
        ])
    }
  }
}
