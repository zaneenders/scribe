import ScribeCore
import SlateCore

struct MarkdownToSlateAdapter {

  static func convert(
    _ line: MarkdownLine,
    baseFG: TerminalRGB,
    baseBold: Bool,
    theme: MarkdownTheme
  ) -> TLine {
    TLine(spans: line.spans.map { convert($0, baseFG: baseFG, baseBold: baseBold, theme: theme) })
  }

  static func convert(
    _ lines: [MarkdownLine],
    baseFG: TerminalRGB,
    baseBold: Bool,
    theme: MarkdownTheme
  ) -> [TLine] {
    lines.map { convert($0, baseFG: baseFG, baseBold: baseBold, theme: theme) }
  }

  static func convert(_ span: StyledSpan, baseFG: TerminalRGB, baseBold: Bool, theme: MarkdownTheme) -> MarkdownSpan {
    let kind = inferKind(fg: span.fg, bold: span.bold, baseFG: baseFG, baseBold: baseBold, theme: theme)
    return MarkdownSpan(text: span.text, kind: kind)
  }

  static func convert(_ line: TLine, baseFG: TerminalRGB, baseBold: Bool, theme: MarkdownTheme) -> MarkdownLine {
    MarkdownLine(spans: line.spans.map { convert($0, baseFG: baseFG, baseBold: baseBold, theme: theme) })
  }

  private static func convert(
    _ span: MarkdownSpan,
    baseFG: TerminalRGB,
    baseBold: Bool,
    theme: MarkdownTheme
  ) -> StyledSpan {
    switch span.kind {
    case .plain:
      StyledSpan(fg: baseFG, bg: theme.background, bold: baseBold, text: span.text)
    case .bold:
      StyledSpan(fg: theme.bold, bg: theme.background, bold: true, text: span.text)
    case .italic:
      StyledSpan(fg: theme.italic, bg: theme.background, bold: baseBold, text: span.text)
    case .code:
      StyledSpan(fg: theme.code, bg: theme.background, bold: false, text: span.text)
    case .headingPrefix:
      StyledSpan(fg: theme.headingPrefix, bg: theme.background, bold: false, text: span.text)
    case .heading:
      StyledSpan(fg: theme.heading, bg: theme.background, bold: true, text: span.text)
    case .listMarker:
      StyledSpan(fg: theme.listMarker, bg: theme.background, bold: false, text: span.text)
    case .blockquote:
      StyledSpan(fg: theme.blockquote, bg: theme.background, bold: false, text: span.text)
    case .link:
      StyledSpan(fg: theme.link, bg: theme.background, bold: baseBold, text: span.text)
    case .codeBlock:
      StyledSpan(fg: theme.codeBlock, bg: theme.background, bold: false, text: span.text)
    case .thematicBreak:
      StyledSpan(fg: theme.hr, bg: theme.background, bold: false, text: span.text)
    case .tableBorder:
      StyledSpan(fg: theme.muted, bg: theme.background, bold: false, text: span.text)
    case .muted:
      StyledSpan(fg: theme.muted, bg: theme.background, bold: false, text: span.text)
    }
  }

  private static func inferKind(
    fg: TerminalRGB,
    bold: Bool,
    baseFG: TerminalRGB,
    baseBold: Bool,
    theme: MarkdownTheme
  ) -> MarkdownSpanKind {
    if fg == theme.bold && bold { return .bold }
    if fg == theme.italic { return .italic }
    if fg == theme.code { return .code }
    if fg == theme.headingPrefix { return .headingPrefix(level: 0) }
    if fg == theme.heading && bold { return .heading(level: 0) }
    if fg == theme.listMarker { return .listMarker }
    if fg == theme.blockquote { return .blockquote }
    if fg == theme.link { return .link }
    if fg == theme.codeBlock { return .codeBlock }
    if fg == theme.hr { return .thematicBreak }
    if fg == theme.muted { return .muted }
    if fg == baseFG && bold == baseBold { return .plain }
    return .plain
  }
}
