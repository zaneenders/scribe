import Markdown

/// A ``MarkdownRenderer`` backed by Apple's `swift-markdown` (CommonMark/GFM).
///
/// Parses the complete markdown buffer on every call and produces semantic
/// ``MarkdownLine``s.  Designed to be stateless so it can be invoked on every SSE
/// chunk without accumulating internal state.
public struct SwiftMarkdownRenderer: MarkdownRenderer {
    public var codeBlockHighlighter: MarkdownCodeBlockHighlighter

    public init(codeBlockHighlighter: MarkdownCodeBlockHighlighter = PlainMarkdownCodeBlockHighlighter()) {
        self.codeBlockHighlighter = codeBlockHighlighter
    }

    public func render(text: String) -> [MarkdownLine] {
        let document = Document(parsing: text)
        var walker = TerminalMarkdownWalker(
            codeBlockHighlighter: codeBlockHighlighter
        )
        walker.visit(document)
        return walker.lines.map { styleRemainingMarkdown(in: $0) }
    }

    /// Fast streaming path: inline-only styling without block-level parsing.
    /// Splits on newlines and applies the safety-net inline pattern styler
    /// (`**bold**`, `*italic*`, `` `code` ``) to each line.
    public func renderStreaming(text: String) -> [MarkdownLine] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let spans = splitMarkdownPatterns(in: String(line))
            return MarkdownLine(spans: spans)
        }
    }
}

// MARK: - Safety-net inline scanner

/// Scans a rendered line for any `**text**`, `*text*`, or `` `text` `` patterns
/// that `swift-markdown` left unparsed and styles them inline.
///
/// Processes *contiguous runs* of body-styled spans together so patterns that
/// the parser split across multiple nodes are still caught.
private func styleRemainingMarkdown(in line: MarkdownLine) -> MarkdownLine {
    guard !line.spans.isEmpty else { return line }

    var newSpans: [MarkdownSpan] = []
    var i = 0
    while i < line.spans.count {
        // Find the next run of contiguous body spans.
        var runStart = i
        while runStart < line.spans.count {
            if case .body = line.spans[runStart] {
                break
            }
            runStart += 1
        }
        // Copy over any non-body spans before the run.
        while i < runStart {
            newSpans.append(line.spans[i])
            i += 1
        }
        guard runStart < line.spans.count else { break }

        var runEnd = runStart
        var concatenated = ""
        while runEnd < line.spans.count {
            guard case .body(let text) = line.spans[runEnd] else { break }
            concatenated += text
            runEnd += 1
        }

        // Run the safety net on the concatenated text.
        let styled = splitMarkdownPatterns(in: concatenated)
        newSpans.append(contentsOf: styled)
        i = runEnd
    }

    return MarkdownLine(spans: newSpans)
}

/// Splits plain text into semantic spans, styling any inline markdown delimiters found.
private func splitMarkdownPatterns(in text: String) -> [MarkdownSpan] {
    var spans: [MarkdownSpan] = []
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
                // Skip `*` that is part of `**`
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
            // No more delimiters — append rest as plain body text.
            spans.append(.body(remaining))
            break
        }

        // Append plain text before the opener.
        if open.range.lowerBound > remaining.startIndex {
            let prefix = String(remaining[..<open.range.lowerBound])
            spans.append(.body(prefix))
        }

        // Look for the matching closer after the opener.
        let afterOpen = open.range.upperBound
        guard let closeRange = remaining[afterOpen...].range(of: delimiterText(for: open.kind)) else {
            // No closer — treat the opener as literal text and continue after it.
            spans.append(.body(delimiterText(for: open.kind)))
            remaining = String(remaining[afterOpen...])
            continue
        }
        let content = String(remaining[afterOpen..<closeRange.lowerBound])

        // Style the content.
        switch open.kind {
        case .strong:
            spans.append(.bold(content))
        case .emphasis:
            spans.append(.italic(content))
        case .code:
            spans.append(.code(content))
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

private enum SpanContext: Equatable {
    case body
    case heading
    case blockquote
}

private enum InlineContext: Equatable {
    case none
    case emphasis
    case strikethrough
    case link(url: String)
}

private struct TerminalMarkdownWalker: MarkupWalker {
    var lines: [MarkdownLine] = []
    var currentLine = MarkdownLine(spans: [])

    var bold: Bool = false
    var spanContext: SpanContext = .body
    var inlineContext: InlineContext = .none

    let codeBlockHighlighter: MarkdownCodeBlockHighlighter

    init(codeBlockHighlighter: MarkdownCodeBlockHighlighter) {
        self.codeBlockHighlighter = codeBlockHighlighter
    }

    // MARK: Helpers

    mutating func flushLine() {
        lines.append(currentLine)
        currentLine = MarkdownLine(spans: [])
    }

    mutating func appendSpan(_ span: MarkdownSpan) {
        currentLine.spans.append(span)
    }

    /// Append text using the current bold flag and span context.
    mutating func appendText(_ text: String, bold: Bool? = nil) {
        let useBold = bold ?? self.bold
        let span: MarkdownSpan
        switch inlineContext {
        case .none:
            switch spanContext {
            case .body:
                span = useBold ? .bold(text) : .body(text)
            case .heading:
                span = .heading(text)
            case .blockquote:
                span = useBold ? .bold(text) : .blockquote(text)
            }
        case .emphasis:
            span = .italic(text)
        case .strikethrough:
            span = .strikethrough(text)
        case .link(let url):
            span = .link(text: text, url: url)
        }
        currentLine.spans.append(span)
    }

    // MARK: Block elements

    mutating func visitParagraph(_ paragraph: Paragraph) {
        let savedContext = spanContext
        spanContext = .body
        for child in paragraph.inlineChildren {
            visit(child)
        }
        spanContext = savedContext
        if !currentLine.spans.isEmpty {
            flushLine()
        }
    }

    mutating func visitHeading(_ heading: Heading) {
        let prefix = String(repeating: "#", count: heading.level) + " "
        appendSpan(.body(prefix))
        let savedContext = spanContext
        spanContext = .heading
        for child in heading.inlineChildren {
            visit(child)
        }
        spanContext = savedContext
        if !currentLine.spans.isEmpty {
            flushLine()
        }
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
        let fence = "```" + (codeBlock.language ?? "")
        lines.append(MarkdownLine(spans: [.codeBlock(fence)]))
        let highlighted = codeBlockHighlighter.highlight(code: codeBlock.code, language: codeBlock.language)
        lines.append(contentsOf: highlighted)
        lines.append(MarkdownLine(spans: [.codeBlock("```")]))
    }

    mutating func visitThematicBreak(_: ThematicBreak) {
        lines.append(MarkdownLine(spans: [.thematicBreak]))
    }

    mutating func visitTable(_ table: Table) {
        // Snapshot state so cell visits don't pollute the outer line buffer.
        let savedLines = lines
        let savedCurrent = currentLine

        var allRows: [[MarkdownLine]] = []

        // Header cells
        var headerCells: [MarkdownLine] = []
        for cell in table.head.cells {
            lines = []
            currentLine = MarkdownLine(spans: [])
            visit(cell)
            headerCells.append(currentLine)
        }
        if !headerCells.isEmpty {
            allRows.append(headerCells)
        }

        // Body rows
        for tableRow in table.body.rows {
            var bodyCells: [MarkdownLine] = []
            for cell in tableRow.cells {
                lines = []
                currentLine = MarkdownLine(spans: [])
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
                let w = cell.spans.reduce(0) { $0 + $1.plainText.count }
                colWidths[c] = max(colWidths[c], w)
            }
        }

        let pad = 1  // one space on each side of content

        // Top border
        var top = ""
        top += "┌"
        for c in 0..<columnCount {
            top += String(repeating: "─", count: colWidths[c] + pad * 2)
            if c < columnCount - 1 { top += "┬" }
        }
        top += "┐"
        lines.append(MarkdownLine(spans: [.body(top)]))

        // Rows
        for (rowIdx, row) in allRows.enumerated() {
            var rowSpans: [MarkdownSpan] = []
            rowSpans.append(.body("│ "))

            for c in 0..<columnCount {
                let cell = c < row.count ? row[c] : MarkdownLine(spans: [])
                let textWidth = cell.spans.reduce(0) { $0 + $1.plainText.count }
                let padding = max(0, colWidths[c] - textWidth)
                let isHeader = (rowIdx == 0)

                if isHeader {
                    // Header: bold everything
                    for s in cell.spans {
                        rowSpans.append(.bold(s.plainText))
                    }
                } else {
                    rowSpans.append(contentsOf: cell.spans)
                }
                // Pad with spaces
                if padding > 0 {
                    rowSpans.append(.body(String(repeating: " ", count: padding)))
                }
                rowSpans.append(.body(" │ "))
            }
            // Replace last " │ " with " │"
            if !rowSpans.isEmpty {
                rowSpans[rowSpans.count - 1] = .body(" │")
            }
            lines.append(MarkdownLine(spans: rowSpans))

            // Separator after header
            if rowIdx == 0 {
                var sep = ""
                sep += "├"
                for c in 0..<columnCount {
                    sep += String(repeating: "─", count: colWidths[c] + pad * 2)
                    if c < columnCount - 1 { sep += "┼" }
                }
                sep += "┤"
                lines.append(MarkdownLine(spans: [.body(sep)]))
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
        lines.append(MarkdownLine(spans: [.body(bottom)]))
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
        let savedBold = bold
        let savedContext = spanContext
        spanContext = .blockquote
        bold = false

        var quoteLines: [MarkdownLine] = []
        for child in blockQuote.blockChildren {
            let snapshotLines = lines
            let snapshotCurrent = currentLine
            lines = []
            currentLine = MarkdownLine(spans: [])

            visit(child)

            if !currentLine.spans.isEmpty {
                flushLine()
            }
            quoteLines.append(contentsOf: lines)
            lines = snapshotLines
            currentLine = snapshotCurrent
        }

        spanContext = savedContext
        bold = savedBold

        for line in quoteLines {
            var prefixed = line
            prefixed.spans.insert(.blockquote("> "), at: 0)
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
        currentLine = MarkdownLine(spans: [])

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
                modified.spans.insert(.listMarker(bullet), at: 0)
            } else {
                let indent = String(repeating: " ", count: bullet.count)
                modified.spans.insert(.body(indent), at: 0)
            }
            lines.append(modified)
        }
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) {
        appendSpan(.strikethrough(html.rawHTML))
        if !currentLine.spans.isEmpty {
            flushLine()
        }
    }

    // MARK: Inline elements

    mutating func visitText(_ text: Text) {
        // Safety-net: if the parser left `**`, `*`, or `` ` `` unparsed in a
        // plain Text node, style them now before they reach the span buffer.
        let spans = splitMarkdownPatterns(in: text.string)
        for sp in spans {
            // Re-wrap through appendText so the current inlineContext and
            // spanContext are applied.  The safety-net always produces .body
            // for base text and .bold/.italic/.code for matched delimiters.
            switch sp {
            case .body(let t):
                appendText(t)
            case .bold(let t):
                appendText(t, bold: true)
            default:
                appendSpan(sp)
            }
        }
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) {
        let saved = inlineContext
        inlineContext = .emphasis
        for child in emphasis.inlineChildren {
            visit(child)
        }
        inlineContext = saved
    }

    mutating func visitStrong(_ strong: Strong) {
        let savedBold = bold
        bold = true
        for child in strong.inlineChildren {
            visit(child)
        }
        bold = savedBold
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) {
        let saved = inlineContext
        inlineContext = .strikethrough
        for child in strikethrough.inlineChildren {
            visit(child)
        }
        inlineContext = saved
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) {
        appendSpan(.code(inlineCode.code))
    }

    mutating func visitLink(_ link: Link) {
        let saved = inlineContext
        let destination = link.destination ?? ""
        inlineContext = .link(url: destination)
        for child in link.inlineChildren {
            visit(child)
        }
        inlineContext = saved
    }

    mutating func visitImage(_ image: Image) {
        let alt = image.plainText
        appendSpan(.link(text: "[\(alt)]", url: ""))
    }

    mutating func visitLineBreak(_: LineBreak) {
        flushLine()
    }

    mutating func visitSoftBreak(_: SoftBreak) {
        flushLine()
    }

    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) {
        appendSpan(.strikethrough(inlineHTML.rawHTML))
    }
}

// MARK: - Helpers

extension MarkdownSpan {
    /// Plain text content of the span (for width calculations).
    public var plainText: String {
        switch self {
        case .body(let t): return t
        case .bold(let t): return t
        case .italic(let t): return t
        case .code(let t): return t
        case .codeBlock(let t): return t
        case .heading(let t): return t
        case .blockquote(let t): return t
        case .listMarker(let t): return t
        case .thematicBreak: return "---"
        case .link(let t, _): return t
        case .strikethrough(let t): return t
        }
    }
}
