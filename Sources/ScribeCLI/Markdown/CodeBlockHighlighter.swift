import SlateCore

public protocol CodeBlockHighlighter: Sendable {

  func highlight(code: String, language: String?) -> [TLine]
}

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
