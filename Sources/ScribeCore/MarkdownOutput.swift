
/// A styled span of text with a semantic kind (no terminal color dependencies).
/// These types live in `ScribeCore` so they can be used by any host (TUI, web, etc.)
/// without pulling in `SlateCore` or any terminal-specific libraries.
public struct MarkdownSpan: Equatable, Sendable {
  public var text: String
  public var kind: MarkdownSpanKind

  public init(text: String, kind: MarkdownSpanKind) {
    self.text = text
    self.kind = kind
  }
}

/// Semantic style kinds for markdown spans.
/// Hosts map these to their own styling primitives (e.g. terminal colors, HTML classes).
public enum MarkdownSpanKind: Equatable, Sendable {
  case plain
  case bold
  case italic
  case code
  case headingPrefix(level: Int)
  case heading(level: Int)
  case listMarker
  case blockquote
  case link
  case codeBlock
  case thematicBreak
  case tableBorder
  /// Strikethrough, inline HTML, and other de-emphasized content.
  case muted
}

/// A logical line of markdown output, composed of styled spans.
public struct MarkdownLine: Equatable, Sendable {
  public var spans: [MarkdownSpan]

  public init(spans: [MarkdownSpan]) {
    self.spans = spans
  }
}
