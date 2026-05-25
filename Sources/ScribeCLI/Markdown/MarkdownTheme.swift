import SlateCore

public struct MarkdownTheme: Sendable, Equatable {
  public var heading: TerminalRGB
  public var headingPrefix: TerminalRGB
  public var bold: TerminalRGB
  public var italic: TerminalRGB
  public var code: TerminalRGB
  public var codeBlock: TerminalRGB
  public var blockquote: TerminalRGB
  public var listMarker: TerminalRGB
  public var link: TerminalRGB
  public var hr: TerminalRGB

  public var background: TerminalRGB

  public var muted: TerminalRGB

  public init(
    heading: TerminalRGB,
    headingPrefix: TerminalRGB,
    bold: TerminalRGB,
    italic: TerminalRGB,
    code: TerminalRGB,
    codeBlock: TerminalRGB,
    blockquote: TerminalRGB,
    listMarker: TerminalRGB,
    link: TerminalRGB,
    hr: TerminalRGB,
    background: TerminalRGB,
    muted: TerminalRGB
  ) {
    self.heading = heading
    self.headingPrefix = headingPrefix
    self.bold = bold
    self.italic = italic
    self.code = code
    self.codeBlock = codeBlock
    self.blockquote = blockquote
    self.listMarker = listMarker
    self.link = link
    self.hr = hr
    self.background = background
    self.muted = muted
  }

  public static let vibrant = MarkdownTheme(
    heading: ScribePalette.markdownHeading,
    headingPrefix: ScribePalette.markdownHeadingPrefix,
    bold: ScribePalette.markdownBold,
    italic: ScribePalette.markdownItalic,
    code: ScribePalette.markdownCode,
    codeBlock: ScribePalette.markdownCodeBlock,
    blockquote: ScribePalette.markdownBlockquote,
    listMarker: ScribePalette.markdownListMarker,
    link: ScribePalette.markdownLink,
    hr: ScribePalette.markdownHR,
    background: ScribePalette.black,
    muted: ScribePalette.gray
  )

  public static let grayscale = MarkdownTheme(
    heading: ScribePalette.grayHeading,
    headingPrefix: ScribePalette.grayHeadingPrefix,
    bold: ScribePalette.grayBold,
    italic: ScribePalette.grayItalic,
    code: ScribePalette.grayCode,
    codeBlock: ScribePalette.grayCodeBlock,
    blockquote: ScribePalette.grayBlockquote,
    listMarker: ScribePalette.grayListMarker,
    link: ScribePalette.grayLink,
    hr: ScribePalette.grayHR,
    background: ScribePalette.black,
    muted: ScribePalette.gray
  )
}
