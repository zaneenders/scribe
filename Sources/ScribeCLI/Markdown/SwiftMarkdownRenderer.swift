import Markdown
import SlateCore

/// A ``MarkdownRenderer`` backed by Apple's `swift-markdown` (CommonMark/GFM).
///
/// Parses the complete markdown buffer on every call and produces styled
/// ``TLine``s.  Designed to be stateless so it can be invoked on every SSE
/// chunk without accumulating internal state.
public struct SwiftMarkdownRenderer: MarkdownRenderer {
  public var codeBlockHighlighter: CodeBlockHighlighter

  public init(codeBlockHighlighter: CodeBlockHighlighter = PlainCodeBlockHighlighter()) {
    self.codeBlockHighlighter = codeBlockHighlighter
  }

  public func render(text: String, baseFG: TerminalRGB, baseBold: Bool, theme: MarkdownTheme) -> [TLine] {
    let document = Document(parsing: text)
    var walker = TerminalMarkdownWalker(
      baseFG: baseFG,
      baseBold: baseBold,
      codeBlockHighlighter: codeBlockHighlighter,
      theme: theme
    )
    walker.visit(document)
    return walker.lines.map { styleRemainingMarkdown(in: $0, baseFG: baseFG, baseBold: baseBold, theme: theme) }
  }

  /// Fast streaming path: inline-only styling without block-level parsing.
  /// Splits on newlines and applies the safety-net inline pattern styler
  /// (`**bold**`, `*italic*`, `` `code` ``) to each line.
  public func renderStreaming(text: String, baseFG: TerminalRGB, baseBold: Bool, theme: MarkdownTheme) -> [TLine] {
    text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
      let spans = splitMarkdownPatterns(
        in: String(line), baseFG: baseFG, baseBold: baseBold, theme: theme)
      return TLine(spans: spans)
    }
  }
}

/// Scans a rendered line for any `**text**`, `*text*`, or `` `text` `` patterns
/// that `swift-markdown` left unparsed and styles them inline.
///
/// Processes *contiguous runs* of base-styled spans together so patterns that
/// the parser split across multiple Text nodes are still caught.
private func styleRemainingMarkdown(in line: TLine, baseFG: TerminalRGB, baseBold: Bool, theme: MarkdownTheme) -> TLine
{
  guard !line.spans.isEmpty else { return line }

  var newSpans: [StyledSpan] = []
  var i = 0
  while i < line.spans.count {
    // Find the next run of contiguous base-styled spans.
    var runStart = i
    while runStart < line.spans.count {
      let s = line.spans[runStart]
      if s.fg == baseFG, s.bg == theme.background, s.bold == baseBold {
        break
      }
      runStart += 1
    }
    // Copy over any non-base spans before the run.
    while i < runStart {
      newSpans.append(line.spans[i])
      i += 1
    }
    guard runStart < line.spans.count else { break }

    var runEnd = runStart
    var concatenated = ""
    while runEnd < line.spans.count {
      let s = line.spans[runEnd]
      guard s.fg == baseFG, s.bg == theme.background, s.bold == baseBold else { break }
      concatenated += s.text
      runEnd += 1
    }

    // Run the safety net on the concatenated text.
    let styled = splitMarkdownPatterns(in: concatenated, baseFG: baseFG, baseBold: baseBold, theme: theme)
    newSpans.append(contentsOf: styled)
    i = runEnd
  }

  return TLine(spans: newSpans)
}

/// Splits plain text into spans, styling any inline markdown delimiters found.
private func splitMarkdownPatterns(in text: String, baseFG: TerminalRGB, baseBold: Bool, theme: MarkdownTheme)
  -> [StyledSpan]
{
  var spans: [StyledSpan] = []
  var remaining = text

  while !remaining.isEmpty {
    // Find the earliest delimiter among **, *, and ` (but not ```)
    let doubleIdx = remaining.range(of: "**")
    let singleIdx = remaining.range(of: "*")
    let backtickIdx = remaining.range(of: "`")

    var earliest: (range: Range<String.Index>, kind: DelimiterKind)?
    if let r = doubleIdx { earliest = (r, .strong) }
    if let r = singleIdx {
      if earliest == nil || r.lowerBound < earliest!.range.lowerBound {
        // Skip `*` that is part of `**` — we already handled `**` above
        if doubleIdx == nil || r.lowerBound != doubleIdx!.lowerBound {
          earliest = (r, .emphasis)
        }
      }
    }
    if let r = backtickIdx {
      if earliest == nil || r.lowerBound < earliest!.range.lowerBound {
        // Skip `` ` `` at the start of a code-block fence (```)
        let after = remaining.index(after: r.lowerBound)
        if after < remaining.endIndex, remaining[after] == "`" {
          // Could be ``` — skip this backtick
        } else {
          earliest = (r, .code)
        }
      }
    }

    guard let open = earliest else {
      // No more delimiters — append rest as plain text.
      spans.append(StyledSpan(fg: baseFG, bg: theme.background, bold: baseBold, text: remaining))
      break
    }

    // Append plain text before the opener.
    if open.range.lowerBound > remaining.startIndex {
      let prefix = String(remaining[..<open.range.lowerBound])
      spans.append(StyledSpan(fg: baseFG, bg: theme.background, bold: baseBold, text: prefix))
    }

    // Look for the matching closer after the opener.
    let afterOpen = open.range.upperBound
    guard let closeRange = remaining[afterOpen...].range(of: delimiterText(for: open.kind)) else {
      // No closer — treat the opener as literal text and continue after it.
      spans.append(StyledSpan(fg: baseFG, bg: theme.background, bold: baseBold, text: delimiterText(for: open.kind)))
      remaining = String(remaining[afterOpen...])
      continue
    }
    let content = String(remaining[afterOpen..<closeRange.lowerBound])

    // Style the content.
    switch open.kind {
    case .strong:
      spans.append(StyledSpan(fg: theme.bold, bg: theme.background, bold: true, text: content))
    case .emphasis:
      spans.append(StyledSpan(fg: theme.italic, bg: theme.background, bold: baseBold, text: content))
    case .code:
      spans.append(StyledSpan(fg: theme.code, bg: theme.background, bold: false, text: content))
    }

    remaining = String(remaining[closeRange.upperBound...])
  }

  return spans
}

private enum DelimiterKind {
  case strong
  case emphasis
  case code
}

private func delimiterText(for kind: DelimiterKind) -> String {
  switch kind {
  case .strong: return "**"
  case .emphasis: return "*"
  case .code: return "`"
  }
}

// MARK: - Walker

private struct TerminalMarkdownWalker: MarkupWalker {
  var lines: [TLine] = []
  var currentLine = TLine(spans: [])

  var fg: TerminalRGB
  var bg: TerminalRGB
  var bold: Bool

  let codeBlockHighlighter: CodeBlockHighlighter
  let theme: MarkdownTheme

  init(baseFG: TerminalRGB, baseBold: Bool, codeBlockHighlighter: CodeBlockHighlighter, theme: MarkdownTheme) {
    self.fg = baseFG
    self.bg = theme.background
    self.bold = baseBold
    self.codeBlockHighlighter = codeBlockHighlighter
    self.theme = theme
  }

  // MARK: Helpers

  mutating func flushLine() {
    lines.append(currentLine)
    currentLine = TLine(spans: [])
  }

  mutating func appendText(_ text: String, fg: TerminalRGB? = nil, bold: Bool? = nil) {
    let spanFG = fg ?? self.fg
    let spanBold = bold ?? self.bold
    if var last = currentLine.spans.last,
      last.fg == spanFG,
      last.bg == bg,
      last.bold == spanBold
    {
      last.text += text
      currentLine.spans[currentLine.spans.count - 1] = last
    } else {
      currentLine.spans.append(StyledSpan(fg: spanFG, bg: bg, bold: spanBold, text: text))
    }
  }

  // MARK: Block elements

  mutating func visitParagraph(_ paragraph: Paragraph) {
    for child in paragraph.inlineChildren {
      visit(child)
    }
    if !currentLine.spans.isEmpty {
      flushLine()
    }
  }

  mutating func visitHeading(_ heading: Heading) {
    let prefix = String(repeating: "#", count: heading.level) + " "
    appendText(prefix, fg: theme.headingPrefix, bold: false)
    let savedFG = fg
    let savedBold = bold
    fg = theme.heading
    bold = true
    for child in heading.inlineChildren {
      visit(child)
    }
    fg = savedFG
    bold = savedBold
    if !currentLine.spans.isEmpty {
      flushLine()
    }
  }

  mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
    let cbFG = theme.codeBlock
    let fence = "```" + (codeBlock.language ?? "")
    lines.append(
      TLine(
        spans: [
          StyledSpan(fg: cbFG, bg: bg, bold: false, text: fence)
        ]))
    var highlighted = codeBlockHighlighter.highlight(code: codeBlock.code, language: codeBlock.language)
    // Remap highlighted lines to the theme's code-block color so themes
    // like grayscale can override the highlighter's default palette.
    highlighted = highlighted.map { line in
      TLine(
        spans: line.spans.map { s in
          StyledSpan(fg: cbFG, bg: s.bg, bold: s.bold, text: s.text)
        })
    }
    lines.append(contentsOf: highlighted)
    lines.append(
      TLine(
        spans: [
          StyledSpan(fg: cbFG, bg: bg, bold: false, text: "```")
        ]))
  }

  mutating func visitThematicBreak(_: ThematicBreak) {
    lines.append(
      TLine(
        spans: [
          StyledSpan(fg: theme.hr, bg: bg, bold: false, text: "---")
        ]))
  }

  mutating func visitTable(_ table: Table) {
    // Snapshot state so cell visits don't pollute the outer line buffer.
    let savedLines = lines
    let savedCurrent = currentLine

    var allRows: [[TLine]] = []

    // Header cells (Table.Head is a TableCellContainer — no intermediate Row)
    var headerCells: [TLine] = []
    for cell in table.head.cells {
      lines = []
      currentLine = TLine(spans: [])
      visit(cell)
      headerCells.append(currentLine)
    }
    if !headerCells.isEmpty {
      allRows.append(headerCells)
    }

    // Body rows
    for tableRow in table.body.rows {
      var bodyCells: [TLine] = []
      for cell in tableRow.cells {
        lines = []
        currentLine = TLine(spans: [])
        visit(cell)
        bodyCells.append(currentLine)
      }
      allRows.append(bodyCells)
    }

    lines = savedLines
    currentLine = savedCurrent

    guard !allRows.isEmpty else { return }
    let columnCount = allRows.map { $0.count }.max() ?? 0
    guard columnCount > 0 else { return }

    // Compute natural column widths from visible text.
    var colWidths: [Int] = Array(repeating: 0, count: columnCount)
    for row in allRows {
      for (c, cell) in row.enumerated() {
        let w = cell.spans.reduce(0) { $0 + $1.text.count }
        colWidths[c] = max(colWidths[c], w)
      }
    }

    let borderFG = theme.muted
    let pad = 1  // one space on each side of content

    // Top border
    var top = ""
    top += "┌"
    for c in 0..<columnCount {
      top += String(repeating: "─", count: colWidths[c] + pad * 2)
      if c < columnCount - 1 { top += "┬" }
    }
    top += "┐"
    lines.append(TLine(spans: [StyledSpan(fg: borderFG, bg: bg, bold: false, text: top)]))

    // Rows
    for (rowIdx, row) in allRows.enumerated() {
      var rowSpans: [StyledSpan] = []
      rowSpans.append(StyledSpan(fg: borderFG, bg: bg, bold: false, text: "│ "))

      for c in 0..<columnCount {
        let cell = c < row.count ? row[c] : TLine(spans: [])
        let textWidth = cell.spans.reduce(0) { $0 + $1.text.count }
        let padding = max(0, colWidths[c] - textWidth)
        let isHeader = (rowIdx == 0)

        if isHeader {
          // Header: bold everything, use heading color
          for s in cell.spans {
            rowSpans.append(StyledSpan(fg: theme.heading, bg: bg, bold: true, text: s.text))
          }
        } else {
          rowSpans.append(contentsOf: cell.spans)
        }
        // Pad with spaces
        if padding > 0 {
          rowSpans.append(StyledSpan(fg: fg, bg: bg, bold: false, text: String(repeating: " ", count: padding)))
        }
        rowSpans.append(StyledSpan(fg: borderFG, bg: bg, bold: false, text: " │ "))
      }
      // Replace last " │ " with " │"
      if !rowSpans.isEmpty {
        rowSpans[rowSpans.count - 1] = StyledSpan(fg: borderFG, bg: bg, bold: false, text: " │")
      }
      lines.append(TLine(spans: rowSpans))

      // Separator after header
      if rowIdx == 0 {
        var sep = ""
        sep += "├"
        for c in 0..<columnCount {
          sep += String(repeating: "─", count: colWidths[c] + pad * 2)
          if c < columnCount - 1 { sep += "┼" }
        }
        sep += "┤"
        lines.append(TLine(spans: [StyledSpan(fg: borderFG, bg: bg, bold: false, text: sep)]))
      }
    }

    // Bottom border
    var bottom = ""
    bottom += "└"
    for c in 0..<columnCount {
      bottom += String(repeating: "─", count: colWidths[c] + pad * 2)
      if c < columnCount - 1 { bottom += "┴" }
    }
    bottom += "┘"
    lines.append(TLine(spans: [StyledSpan(fg: borderFG, bg: bg, bold: false, text: bottom)]))
  }

  mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
    let savedFG = fg
    let savedBold = bold
    fg = theme.blockquote
    bold = false

    var quoteLines: [TLine] = []
    for child in blockQuote.blockChildren {
      let snapshotLines = lines
      let snapshotCurrent = currentLine
      lines = []
      currentLine = TLine(spans: [])

      visit(child)

      if !currentLine.spans.isEmpty {
        flushLine()
      }
      quoteLines.append(contentsOf: lines)
      lines = snapshotLines
      currentLine = snapshotCurrent
    }

    fg = savedFG
    bold = savedBold

    for line in quoteLines {
      var prefixed = line
      prefixed.spans.insert(
        StyledSpan(fg: theme.blockquote, bg: bg, bold: false, text: "> "),
        at: 0)
      lines.append(prefixed)
    }
  }

  mutating func visitUnorderedList(_ unorderedList: UnorderedList) {
    for item in unorderedList.listItems {
      renderListItem(item, bullet: "- ")
    }
  }

  mutating func visitOrderedList(_ orderedList: OrderedList) {
    var number = Int(orderedList.startIndex)
    for item in orderedList.listItems {
      renderListItem(item, bullet: "\(number). ")
      number += 1
    }
  }

  mutating func renderListItem(_ listItem: ListItem, bullet: String) {
    let snapshotLines = lines
    let snapshotCurrent = currentLine
    lines = []
    currentLine = TLine(spans: [])

    for child in listItem.blockChildren {
      visit(child)
    }
    if !currentLine.spans.isEmpty {
      flushLine()
    }

    let itemLines = lines
    lines = snapshotLines
    currentLine = snapshotCurrent

    for (i, line) in itemLines.enumerated() {
      var modified = line
      if i == 0 {
        modified.spans.insert(
          StyledSpan(fg: theme.listMarker, bg: bg, bold: false, text: bullet),
          at: 0)
      } else {
        let indent = String(repeating: " ", count: bullet.count)
        modified.spans.insert(
          StyledSpan(fg: theme.listMarker, bg: bg, bold: false, text: indent),
          at: 0)
      }
      lines.append(modified)
    }
  }

  mutating func visitHTMLBlock(_ html: HTMLBlock) {
    appendText(html.rawHTML, fg: theme.muted)
    if !currentLine.spans.isEmpty {
      flushLine()
    }
  }

  // MARK: Inline elements

  mutating func visitText(_ text: Text) {
    // Safety-net: if the parser left `**`, `*`, or `` ` `` unparsed in a
    // plain Text node, style them now before they reach the span buffer.
    let spans = splitMarkdownPatterns(in: text.string, baseFG: fg, baseBold: bold, theme: theme)
    for sp in spans {
      appendText(sp.text, fg: sp.fg, bold: sp.bold)
    }
  }

  mutating func visitEmphasis(_ emphasis: Emphasis) {
    let savedFG = fg
    fg = theme.italic
    for child in emphasis.inlineChildren {
      visit(child)
    }
    fg = savedFG
  }

  mutating func visitStrong(_ strong: Strong) {
    let savedFG = fg
    let savedBold = bold
    fg = theme.bold
    bold = true
    for child in strong.inlineChildren {
      visit(child)
    }
    fg = savedFG
    bold = savedBold
  }

  mutating func visitStrikethrough(_ strikethrough: Strikethrough) {
    let savedFG = fg
    fg = theme.muted
    for child in strikethrough.inlineChildren {
      visit(child)
    }
    fg = savedFG
  }

  mutating func visitInlineCode(_ inlineCode: InlineCode) {
    appendText(inlineCode.code, fg: theme.code)
  }

  mutating func visitLink(_ link: Link) {
    let savedFG = fg
    fg = theme.link
    for child in link.inlineChildren {
      visit(child)
    }
    fg = savedFG
  }

  mutating func visitImage(_ image: Image) {
    let alt = image.plainText
    appendText("[\(alt)]", fg: theme.link)
  }

  mutating func visitLineBreak(_: LineBreak) {
    flushLine()
  }

  mutating func visitSoftBreak(_: SoftBreak) {
    flushLine()
  }

  mutating func visitInlineHTML(_ inlineHTML: InlineHTML) {
    appendText(inlineHTML.rawHTML, fg: theme.muted)
  }
}
