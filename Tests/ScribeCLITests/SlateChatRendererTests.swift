import SlateCore
import Testing

@testable import ScribeCLI

/// Tests for `SlateChatRenderer.paintInputRows` — mode-label rendering, cursor,
/// gutter, and spinner behavior in the input strip.
@Suite
struct SlateChatRendererPaintInputRowsTests {

  // MARK: - Mode label

  @Test func editModeShowsEDITLabelInUserPrefixColor() {
    let theme = CLITheme.default
    let grid = TerminalCellGrid(cols: 40, rows: 3, filling: .empty)

    var g = grid
    SlateChatRenderer.paintInputRows(
      into: &g,
      startRow: 0,
      cols: 40,
      textWidth: 34,
      visualLines: ["hello"],
      rowCount: 1,
      inputMode: .edit,
      llmWaitAnimationFrame: 0,
      showSpinner: false,
      agentBusy: false,
      theme: theme)

    // "EDIT: " = 6 chars
    #expect(g[column: 0, row: 0].glyph == "E")
    #expect(g[column: 0, row: 0].foreground == theme.userPrefix)
    #expect(g[column: 1, row: 0].glyph == "D")
    #expect(g[column: 2, row: 0].glyph == "I")
    #expect(g[column: 3, row: 0].glyph == "T")
    #expect(g[column: 4, row: 0].glyph == ":")
    #expect(g[column: 5, row: 0].glyph == " ")
  }

  @Test func readModeShowsREADLabelInScribePrefixColor() {
    let theme = CLITheme.default
    let grid = TerminalCellGrid(cols: 40, rows: 3, filling: .empty)

    var g = grid
    SlateChatRenderer.paintInputRows(
      into: &g,
      startRow: 0,
      cols: 40,
      textWidth: 34,
      visualLines: ["hello"],
      rowCount: 1,
      inputMode: .read,
      llmWaitAnimationFrame: 0,
      showSpinner: false,
      agentBusy: false,
      theme: theme)

    // "READ: " = 6 chars in scribePrefix color
    #expect(g[column: 0, row: 0].glyph == "R")
    #expect(g[column: 0, row: 0].foreground == theme.scribePrefix)
    #expect(g[column: 1, row: 0].glyph == "E")
    #expect(g[column: 2, row: 0].glyph == "A")
    #expect(g[column: 3, row: 0].glyph == "D")
    #expect(g[column: 4, row: 0].glyph == ":")
    #expect(g[column: 5, row: 0].glyph == " ")
  }

  // MARK: - Input text rendering

  @Test func inputTextRendersAfterModeLabel() {
    let theme = CLITheme.default
    let grid = TerminalCellGrid(cols: 40, rows: 3, filling: .empty)

    var g = grid
    SlateChatRenderer.paintInputRows(
      into: &g,
      startRow: 0,
      cols: 40,
      textWidth: 34,
      visualLines: ["hello"],
      rowCount: 1,
      inputMode: .edit,
      llmWaitAnimationFrame: 0,
      showSpinner: false,
      agentBusy: false,
      theme: theme)

    // Text starts after "EDIT: "
    #expect(g[column: 6, row: 0].glyph == "h")
    #expect(g[column: 6, row: 0].foreground == theme.inputText)
    #expect(g[column: 7, row: 0].glyph == "e")
    #expect(g[column: 8, row: 0].glyph == "l")
    #expect(g[column: 9, row: 0].glyph == "l")
    #expect(g[column: 10, row: 0].glyph == "o")
  }

  // MARK: - Cursor

  @Test func cursorRendersOnLastInputRow() {
    let theme = CLITheme.default
    let grid = TerminalCellGrid(cols: 40, rows: 3, filling: .empty)

    var g = grid
    SlateChatRenderer.paintInputRows(
      into: &g,
      startRow: 0,
      cols: 40,
      textWidth: 34,
      visualLines: ["ab"],
      rowCount: 1,
      inputMode: .edit,
      llmWaitAnimationFrame: 0,
      showSpinner: false,
      agentBusy: false,
      theme: theme)

    // Cursor glyph "▏" appears after the text on the last (only) row
    #expect(g[column: 8, row: 0].glyph == "▏")
    #expect(g[column: 8, row: 0].foreground == theme.inputCursor)
  }

  @Test func cursorAppearsOnLastRowWithMultipleRows() {
    let theme = CLITheme.default
    let grid = TerminalCellGrid(cols: 40, rows: 5, filling: .empty)

    var g = grid
    SlateChatRenderer.paintInputRows(
      into: &g,
      startRow: 2,
      cols: 40,
      textWidth: 34,
      visualLines: ["first line", "second line"],
      rowCount: 2,
      inputMode: .edit,
      llmWaitAnimationFrame: 0,
      showSpinner: false,
      agentBusy: false,
      theme: theme)

    // Row 2 (first input row) — no cursor, has mode label
    #expect(g[column: 0, row: 2].glyph == "E")
    // Row 3 (last input row) — has cursor, no mode label (gutter instead)
    #expect(g[column: 0, row: 3].glyph == " ")  // gutter space
    // Cursor should be on row 3 after the text
    let cursorCol = 6 + "second line".count  // gutter + text
    #expect(g[column: cursorCol, row: 3].glyph == "▏")
    #expect(g[column: cursorCol, row: 3].foreground == theme.inputCursor)
  }

  // MARK: - Gutter on continuation rows

  @Test func continuationRowsUseGutterNotModeLabel() {
    let theme = CLITheme.default
    let grid = TerminalCellGrid(cols: 40, rows: 5, filling: .empty)

    var g = grid
    SlateChatRenderer.paintInputRows(
      into: &g,
      startRow: 1,
      cols: 40,
      textWidth: 34,
      visualLines: ["line one", "line two"],
      rowCount: 2,
      inputMode: .edit,
      llmWaitAnimationFrame: 0,
      showSpinner: false,
      agentBusy: false,
      theme: theme)

    // Row 1 — mode label
    #expect(g[column: 0, row: 1].glyph == "E")
    // Row 2 — gutter (6 spaces)
    #expect(g[column: 0, row: 2].glyph == " ")
    #expect(g[column: 0, row: 2].foreground == theme.inputGutter)
    #expect(g[column: 5, row: 2].glyph == " ")
    #expect(g[column: 5, row: 2].foreground == theme.inputGutter)
  }

  // MARK: - Spinner behavior

  @Test func showSpinnerReplacesTextWithSpinnerGlyph() {
    let theme = CLITheme.default
    let grid = TerminalCellGrid(cols: 40, rows: 3, filling: .empty)

    var g = grid
    SlateChatRenderer.paintInputRows(
      into: &g,
      startRow: 0,
      cols: 40,
      textWidth: 34,
      visualLines: [],
      rowCount: 1,
      inputMode: .edit,
      llmWaitAnimationFrame: 3,  // selects 4th spinner glyph: "⢿"
      showSpinner: true,
      agentBusy: false,
      theme: theme)

    // Mode label still shows
    #expect(g[column: 0, row: 0].glyph == "E")
    // Spinner glyph after mode label
    #expect(g[column: 6, row: 0].glyph == "⢿")
    #expect(g[column: 6, row: 0].foreground == theme.spinnerGlyph)
    // Cursor after spinner
    #expect(g[column: 7, row: 0].glyph == "▏")
  }

  @Test func agentBusyShowsSpinnerWhileTyping() {
    let theme = CLITheme.default
    let grid = TerminalCellGrid(cols: 40, rows: 3, filling: .empty)

    var g = grid
    SlateChatRenderer.paintInputRows(
      into: &g,
      startRow: 0,
      cols: 40,
      textWidth: 34,
      visualLines: ["typing"],
      rowCount: 1,
      inputMode: .edit,
      llmWaitAnimationFrame: 0,  // ⣾
      showSpinner: false,
      agentBusy: true,
      theme: theme)

    // Mode label
    #expect(g[column: 0, row: 0].glyph == "E")
    // Spinner after mode label (even though showSpinner is false and we have text)
    #expect(g[column: 6, row: 0].glyph == "⣾")
    #expect(g[column: 6, row: 0].foreground == theme.spinnerGlyph)
    // Text starts 1 column later (spinnerPad)
    #expect(g[column: 7, row: 0].glyph == "t")
    // Cursor after text
    #expect(g[column: 13, row: 0].glyph == "▏")
  }

  @Test func agentIdleNoSpinnerWithText() {
    let theme = CLITheme.default
    let grid = TerminalCellGrid(cols: 40, rows: 3, filling: .empty)

    var g = grid
    SlateChatRenderer.paintInputRows(
      into: &g,
      startRow: 0,
      cols: 40,
      textWidth: 34,
      visualLines: ["typing"],
      rowCount: 1,
      inputMode: .edit,
      llmWaitAnimationFrame: 0,
      showSpinner: false,
      agentBusy: false,
      theme: theme)

    // Mode label
    #expect(g[column: 0, row: 0].glyph == "E")
    // Text immediately follows (no spinner)
    #expect(g[column: 6, row: 0].glyph == "t")
  }

  // MARK: - Background fill

  @Test func inputRowsUseInputAreaBackground() {
    let theme = CLITheme.default
    let grid = TerminalCellGrid(cols: 40, rows: 3, filling: .empty)

    var g = grid
    SlateChatRenderer.paintInputRows(
      into: &g,
      startRow: 0,
      cols: 40,
      textWidth: 34,
      visualLines: ["x"],
      rowCount: 1,
      inputMode: .edit,
      llmWaitAnimationFrame: 0,
      showSpinner: false,
      agentBusy: false,
      theme: theme)

    // All cells on the painted row should have inputAreaBg background
    #expect(g[column: 0, row: 0].background == theme.inputAreaBg)
    #expect(g[column: 6, row: 0].background == theme.inputAreaBg)
    #expect(g[column: 7, row: 0].background == theme.inputAreaBg)
  }

  // MARK: - Bounds safety

  @Test func paintInputRowsClipsToGridBounds() {
    let theme = CLITheme.default
    let grid = TerminalCellGrid(cols: 10, rows: 3, filling: .empty)

    var g = grid
    // Text wider than grid — should not crash
    SlateChatRenderer.paintInputRows(
      into: &g,
      startRow: 0,
      cols: 10,
      textWidth: 4,
      visualLines: ["very long text that overflows"],
      rowCount: 1,
      inputMode: .edit,
      llmWaitAnimationFrame: 0,
      showSpinner: false,
      agentBusy: false,
      theme: theme)

    // Should still render without crashing — just verify first cells
    #expect(g[column: 0, row: 0].glyph == "E")
  }

  @Test func paintInputRowsNegativeStartRowIsSafe() {
    let theme = CLITheme.default
    let grid = TerminalCellGrid(cols: 40, rows: 3, filling: .empty)

    var g = grid
    // Negative startRow — should not crash, just skip rendering
    SlateChatRenderer.paintInputRows(
      into: &g,
      startRow: -1,
      cols: 40,
      textWidth: 34,
      visualLines: ["hello"],
      rowCount: 1,
      inputMode: .edit,
      llmWaitAnimationFrame: 0,
      showSpinner: false,
      agentBusy: false,
      theme: theme)

    // Grid should be unchanged (still all empty cells)
    #expect(g[column: 0, row: 0].glyph == " ")
  }
}

// MARK: - prepareInputRows

/// Tests for `SlateChatRenderer.prepareInputRows` — visual-line wrapping, extra
/// cursor row, and row-count clamping.
@Suite
struct SlateChatRendererPrepareInputRowsTests {

  @Test func emptyTextReturnsOneBlankRow() {
    let (visualLines, rowCount) = SlateChatRenderer.prepareInputRows(
      text: "", textWidth: 40, maxRows: 8)
    #expect(rowCount == 1)
    #expect(visualLines == [""])
  }

  @Test func zeroTextWidthReturnsOneBlankRow() {
    let (visualLines, rowCount) = SlateChatRenderer.prepareInputRows(
      text: "hello", textWidth: 0, maxRows: 8)
    #expect(rowCount == 1)
    #expect(visualLines == [""])
  }

  @Test func singleLineFitsInOneRow() {
    let (visualLines, rowCount) = SlateChatRenderer.prepareInputRows(
      text: "hello", textWidth: 40, maxRows: 8)
    #expect(rowCount == 1)
    #expect(visualLines == ["hello"])
  }

  @Test func longLineWrapsToMultipleVisualLines() {
    // "1234567890" with width 3 → wraps to 4 lines: "123", "456", "789", "0"
    let (visualLines, rowCount) = SlateChatRenderer.prepareInputRows(
      text: "1234567890", textWidth: 3, maxRows: 8)
    #expect(rowCount == 4)
    #expect(visualLines[0] == "123")
    #expect(visualLines[1] == "456")
    #expect(visualLines[2] == "789")
    #expect(visualLines[3] == "0")
  }

  @Test func lineExactlyFillingWidthNeedsExtraCursorRow() {
    // "123" with width 3 → fills exactly, needs extra cursor row
    let (visualLines, rowCount) = SlateChatRenderer.prepareInputRows(
      text: "123", textWidth: 3, maxRows: 8)
    #expect(rowCount == 2)
    #expect(visualLines == ["123", ""])
  }

  @Test func newlinesCreateMultipleVisualRows() {
    let (visualLines, rowCount) = SlateChatRenderer.prepareInputRows(
      text: "a\nb\nc", textWidth: 40, maxRows: 8)
    #expect(rowCount == 3)
    #expect(visualLines == ["a", "b", "c"])
  }

  @Test func moreLinesThanMaxAreClamped() {
    // maxRows=3, 10 visual lines → clamped to 3 (last 3 visible)
    let text = (0..<10).map { String(UnicodeScalar(65 + $0)!) }.joined(separator: "\n")
    let (visualLines, rowCount) = SlateChatRenderer.prepareInputRows(
      text: text, textWidth: 40, maxRows: 3)
    #expect(rowCount == 3)
    #expect(visualLines == ["H", "I", "J"])
  }

  @Test func clampedToOneRow() {
    let (visualLines, rowCount) = SlateChatRenderer.prepareInputRows(
      text: "line1\nline2\nline3", textWidth: 40, maxRows: 1)
    #expect(rowCount == 1)
    #expect(visualLines == ["line3"])
  }

  @Test func maxRowsLargerThanLinesDoesNotPad() {
    // maxRows=5 but only 2 visual lines → returns exactly 2 rows (no padding)
    let (visualLines, rowCount) = SlateChatRenderer.prepareInputRows(
      text: "a\nb", textWidth: 40, maxRows: 5)
    #expect(rowCount == 2)
    #expect(visualLines == ["a", "b"])
  }

  @Test func maxRowsZeroYieldsZeroRowCount() {
    // maxRows=0 — rowCount = min(0, 1) = 0 (no guard against zero maxRows)
    let (visualLines, rowCount) = SlateChatRenderer.prepareInputRows(
      text: "hello", textWidth: 40, maxRows: 0)
    #expect(rowCount == 0)
    #expect(visualLines == [])
  }

  @Test func wrappedLineWithExtraCursorRowAndClamping() {
    // "1234" with width 3 → wraps to "123", "4". Last line doesn't fill width,
    // so no extra cursor row. rowCount = min(2, 2) = 2.
    let (visualLines, rowCount) = SlateChatRenderer.prepareInputRows(
      text: "1234", textWidth: 3, maxRows: 8)
    #expect(rowCount == 2)
    #expect(visualLines == ["123", "4"])
  }
}

// MARK: - Helper

extension TerminalCell {
  /// A clear/empty cell used as grid fill.
  fileprivate static let empty = TerminalCell(
    glyph: " ",
    foreground: .white,
    background: .black,
    flags: [])
}

// MARK: - queuedTrayVisualLines / queuedTrayRowCount

/// Tests for `SlateChatRenderer.queuedTrayVisualLines` and `queuedTrayRowCount`
/// — tray wrapping, capping, and row counting with the new `[String]` API.
@Suite
struct SlateChatRendererQueuedTrayTests {

  // MARK: - queuedTrayVisualLines

  @Test func emptyArrayReturnsNoVisualLines() {
    let lines = SlateChatRenderer.queuedTrayVisualLines(queuedTrayTexts: [], textWidth: 40)
    #expect(lines.isEmpty)
  }

  @Test func singleMessageWrapsToVisualLines() {
    // "abcde\nfghij" with width 5 → two logical lines
    let lines = SlateChatRenderer.queuedTrayVisualLines(
      queuedTrayTexts: ["abcde\nfghij"], textWidth: 5)
    #expect(lines.count == 2)
    #expect(lines[0] == "abcde")
    #expect(lines[1] == "fghij")
  }

  @Test func usesFirstMessageOnly() {
    let lines = SlateChatRenderer.queuedTrayVisualLines(
      queuedTrayTexts: ["first", "second", "third"], textWidth: 40)
    #expect(lines == ["first"])
  }

  @Test func capsAtMaxTrayRows() {
    // 10 lines of text with width 3 → many visual lines, but capped at 4
    let lines = SlateChatRenderer.queuedTrayVisualLines(
      queuedTrayTexts: ["abcdefghijklmnopqrstuvwxyz"], textWidth: 2)
    #expect(lines.count <= 4)
    #expect(lines.count == 4)
    // Last line should have "…" truncation
    #expect(lines[3].hasSuffix("…"))
  }

  @Test func zeroTextWidthReturnsEmpty() {
    let lines = SlateChatRenderer.queuedTrayVisualLines(
      queuedTrayTexts: ["hello"], textWidth: 0)
    #expect(lines.isEmpty)
  }

  @Test func emptyFirstMessageReturnsEmpty() {
    let lines = SlateChatRenderer.queuedTrayVisualLines(
      queuedTrayTexts: ["", "other"], textWidth: 40)
    #expect(lines.isEmpty)
  }

  // MARK: - queuedTrayRowCount

  @Test func emptyArrayReturnsZeroRows() {
    let count = SlateChatRenderer.queuedTrayRowCount(queuedTrayTexts: [], cols: 80)
    #expect(count == 0)
  }

  @Test func singleMessageReturnsCorrectRowCount() {
    let count = SlateChatRenderer.queuedTrayRowCount(
      queuedTrayTexts: ["hello world"], cols: 80)
    #expect(count == 1)
  }

  @Test func multiLineMessageReturnsCorrectRowCount() {
    let count = SlateChatRenderer.queuedTrayRowCount(
      queuedTrayTexts: ["line1\nline2\nline3"], cols: 80)
    #expect(count == 3)
  }

  // MARK: - paintQueuedTrayRows

  @Test func paintQueuedTrayShowsQueueCountPrefix() {
    let theme = CLITheme.default
    let grid = TerminalCellGrid(cols: 40, rows: 3, filling: .empty)

    var g = grid
    let paintLines = SlateChatRenderer.queuedTrayVisualLines(
      queuedTrayTexts: ["hello"], textWidth: 34)
    SlateChatRenderer.paintQueuedTrayRows(
      into: &g,
      startRow: 0,
      cols: 40,
      textWidth: 34,
      visualLines: paintLines,
      queueCount: 3,
      theme: theme)

    // "queued (3): " prefix in queuedPrefix color
    let prefix = "queued (3): "
    for (i, ch) in prefix.enumerated() {
      #expect(g[column: i, row: 0].glyph == ch)
      #expect(g[column: i, row: 0].foreground == theme.queuedPrefix)
    }
    // Message text in queuedText color
    #expect(g[column: prefix.count, row: 0].glyph == "h")
    #expect(g[column: prefix.count, row: 0].foreground == theme.queuedText)
  }

  @Test func paintQueuedTrayContinuationRowsUseGutter() {
    let theme = CLITheme.default
    let grid = TerminalCellGrid(cols: 40, rows: 3, filling: .empty)

    var g = grid
    let paintLines = SlateChatRenderer.queuedTrayVisualLines(
      queuedTrayTexts: ["line one\nline two"], textWidth: 34)
    SlateChatRenderer.paintQueuedTrayRows(
      into: &g,
      startRow: 0,
      cols: 40,
      textWidth: 34,
      visualLines: paintLines,
      queueCount: 1,
      theme: theme)

    // Row 0: "queued (1): " + "line one"
    #expect(g[column: 0, row: 0].glyph == "q")
    // Row 1: gutter spaces (label-width) in queuedGutter color
    #expect(g[column: 0, row: 1].glyph == " ")
    #expect(g[column: 0, row: 1].foreground == theme.queuedGutter)
  }

  @Test func paintQueuedTrayEmptyVisualLinesIsNoop() {
    let theme = CLITheme.default
    let grid = TerminalCellGrid(cols: 40, rows: 3, filling: .empty)

    var g = grid
    SlateChatRenderer.paintQueuedTrayRows(
      into: &g,
      startRow: 0,
      cols: 40,
      textWidth: 34,
      visualLines: [],
      queueCount: 0,
      theme: theme)

    // Grid should be unchanged
    #expect(g[column: 0, row: 0].glyph == " ")
  }

  @Test func paintQueuedTrayBackgroundUsesInputAreaBg() {
    let theme = CLITheme.default
    let grid = TerminalCellGrid(cols: 40, rows: 3, filling: .empty)

    var g = grid
    let paintLines = SlateChatRenderer.queuedTrayVisualLines(
      queuedTrayTexts: ["test"], textWidth: 34)
    SlateChatRenderer.paintQueuedTrayRows(
      into: &g,
      startRow: 0,
      cols: 40,
      textWidth: 34,
      visualLines: paintLines,
      queueCount: 5,
      theme: theme)

    // All cells on the painted row should have inputAreaBg background
    #expect(g[column: 0, row: 0].background == theme.inputAreaBg)
    #expect(g[column: 13, row: 0].background == theme.inputAreaBg)
  }

  // MARK: - transcriptContentRows

  @Test func transcriptContentRowsAccountsForTrayRows() {
    // With no tray text, content rows = full available space
    let withoutTray = SlateChatRenderer.transcriptContentRows(
      cols: 80, rows: 24,
      banner: nil, usage: nil,
      inputLine: "", waitingForLLM: false,
      queuedTrayTexts: [])
    // With tray text that takes 2 visual rows, content rows should be 2 less
    let withTray = SlateChatRenderer.transcriptContentRows(
      cols: 80, rows: 24,
      banner: nil, usage: nil,
      inputLine: "", waitingForLLM: false,
      queuedTrayTexts: ["line1\nline2"])
    #expect(withTray == withoutTray - 2)
  }
}
