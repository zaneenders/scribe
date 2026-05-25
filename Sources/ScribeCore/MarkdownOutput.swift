public struct MarkdownSpan: Equatable, Sendable {
  public var text: String
  public var kind: MarkdownSpanKind

  public init(text: String, kind: MarkdownSpanKind) {
    self.text = text
    self.kind = kind
  }
}

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

  case muted
}

public struct MarkdownLine: Equatable, Sendable {
  public var spans: [MarkdownSpan]

  public init(spans: [MarkdownSpan]) {
    self.spans = spans
  }
}
