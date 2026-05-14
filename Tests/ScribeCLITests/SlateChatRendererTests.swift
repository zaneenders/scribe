import SlateCore
import Testing

@testable import ScribeCLI

/// Tests for `SlateChatRenderer.buildSemanticInputRows` — mode-label rendering, cursor,
/// gutter, and spinner behavior in the input strip.
@Suite
struct SlateChatRendererBuildSemanticInputRowsTests {

  // MARK: - Mode label

  @Test func editModeShowsEDITLabelInUserPrefixColor() {
    let theme = CLITheme.default
    let cols = 40
    let rows = 3
    var grid = [[StyledSpan]](
      repeating: [StyledSpan](repeating: StyledSpan(fg: .white, bg: .black, bold: false, text: " "), count: cols),
      count: rows
    )

    SlateChatRenderer.buildSemanticInputRows(
      &grid,
      startRow: 0,
      cols: 40,
      textWidth: 34,
      visualLines: ["hello"],
      rowCount: 1,
      inputMode: .edit,
      llmWaitAnimationFrame: 0,
      waitingForLLM: false,
      theme: theme)

    // "EDIT: " = 6 chars
    #expect(grid[0][0].text == "E")
    #expect(grid[0][0].fg == theme.userPrefix)
    #expect(grid[0][1].text == "D")
    #expect(grid[0][2].text == "I")
    #expect(grid[0][3].text == "T")
    #expect(grid[0][4].text == ":")
    #expect(grid[0][5].text == " ")
  }

  @Test func readModeShowsREADLabelInScribePrefixColor() {
    let theme = CLITheme.default
    let cols = 40
    let rows = 3
    var grid = [[StyledSpan]](
      repeating: [StyledSpan](repeating: StyledSpan(fg: .white, bg: .black, bold: false, text: " "), count: cols),
      count: rows
    )

    SlateChatRenderer.buildSemanticInputRows(
      &grid,
      startRow: 0,
      cols: 40,
      textWidth: 34,
      visualLines: ["hello"],
      rowCount: 1,
      inputMode: .read,
      llmWaitAnimationFrame: 0,
      waitingForLLM: false,
      theme: theme)

    // "READ: " = 6 chars in scribePrefix color
    #expect(grid[0][0].text == "R")
    #expect(grid[0][0].fg == theme.scribePrefix)
    #expect(grid[0][1].text == "E")
    #expect(grid[0][2].text == "A")
    #expect(grid[0][3].text == "D")
    #expect(grid[0][4].text == ":")
    #expect(grid[0][5].text == " ")
  }

  // MARK: - Cursor

  @Test func cursorAppearsOnLastRow() {
    let theme = CLITheme.default
    let cols = 40
    let rows = 3
    var grid = [[StyledSpan]](
      repeating: [StyledSpan](repeating: StyledSpan(fg: .white, bg: .black, bold: false, text: " "), count: cols),
      count: rows
    )

    SlateChatRenderer.buildSemanticInputRows(
      &grid,
      startRow: 0,
      cols: 40,
      textWidth: 34,
      visualLines: ["hello"],
      rowCount: 1,
      inputMode: .edit,
      llmWaitAnimationFrame: 0,
      waitingForLLM: false,
      theme: theme)

    // After "EDIT: " (6), "hello" (5) = col 11 should be the cursor
    #expect(grid[0][11].text == "▏")
    #expect(grid[0][11].fg == theme.inputCursor)
  }

  @Test func noCursorOnNonLastRow() {
    let theme = CLITheme.default
    let cols = 40
    let rows = 3
    var grid = [[StyledSpan]](
      repeating: [StyledSpan](repeating: StyledSpan(fg: .white, bg: .black, bold: false, text: " "), count: cols),
      count: rows
    )

    SlateChatRenderer.buildSemanticInputRows(
      &grid,
      startRow: 0,
      cols: 40,
      textWidth: 34,
      visualLines: ["line1", "line2"],
      rowCount: 2,
      inputMode: .edit,
      llmWaitAnimationFrame: 0,
      waitingForLLM: false,
      theme: theme)

    // Row 0 (not last): no cursor — the cursor "▏" only appears on the last row
    // After "EDIT: " (6) + "line1" (5) = 11 chars of content.
    // The cursor glyph should NOT be present on row 0.
    // Row 0 col 11 is beyond the text, should still be background fill.
    #expect(grid[0][11].text == " ")
  }

  // MARK: - Gutter

  @Test func continuationRowsUseGutter() {
    let theme = CLITheme.default
    let cols = 40
    let rows = 3
    var grid = [[StyledSpan]](
      repeating: [StyledSpan](repeating: StyledSpan(fg: .white, bg: .black, bold: false, text: " "), count: cols),
      count: rows
    )

    SlateChatRenderer.buildSemanticInputRows(
      &grid,
      startRow: 0,
      cols: 40,
      textWidth: 34,
      visualLines: ["line1", "line2"],
      rowCount: 2,
      inputMode: .edit,
      llmWaitAnimationFrame: 0,
      waitingForLLM: false,
      theme: theme)

    // Row 0: "EDIT: " + "line1"
    #expect(grid[0][0].text == "E")
    // Row 1: 6-space gutter then "line2"
    #expect(grid[1][0].text == " ")
    #expect(grid[1][0].fg == theme.inputGutter)
    #expect(grid[1][5].text == " ")
    #expect(grid[1][6].text == "l")
  }

  // MARK: - Spinner

  @Test func spinnerShowsWhenWaitingForLLM() {
    let theme = CLITheme.default
    let cols = 40
    let rows = 3
    var grid = [[StyledSpan]](
      repeating: [StyledSpan](repeating: StyledSpan(fg: .white, bg: .black, bold: false, text: " "), count: cols),
      count: rows
    )

    SlateChatRenderer.buildSemanticInputRows(
      &grid,
      startRow: 0,
      cols: 40,
      textWidth: 34,
      visualLines: [],
      rowCount: 1,
      inputMode: .edit,
      llmWaitAnimationFrame: 0,
      waitingForLLM: true,
      theme: theme)

    // Always shows mode label: "EDIT: " or "READ: " (edit → userPrefix orange)
    #expect(grid[0][0].text == "E")
    #expect(grid[0][0].fg == theme.userPrefix)
    // After mode label is spinner glyph, then cursor (no "thinking..." text)
  }

  // MARK: - Clipping

  @Test func buildSemanticInputRowsClipsToGridBounds() {
    let theme = CLITheme.default
    let cols = 10
    let rows = 2
    var grid = [[StyledSpan]](
      repeating: [StyledSpan](repeating: StyledSpan(fg: .white, bg: .black, bold: false, text: " "), count: cols),
      count: rows
    )

    // Should not crash with startRow beyond grid
    SlateChatRenderer.buildSemanticInputRows(
      &grid,
      startRow: 5,
      cols: 10,
      textWidth: 4,
      visualLines: ["hello"],
      rowCount: 1,
      inputMode: .edit,
      llmWaitAnimationFrame: 0,
      waitingForLLM: false,
      theme: theme)

    // Grid should be unchanged
    #expect(grid[0][0].text == " ")
  }

  @Test func buildSemanticInputRowsNegativeStartRowIsSafe() {
    let theme = CLITheme.default
    let cols = 10
    let rows = 2
    var grid = [[StyledSpan]](
      repeating: [StyledSpan](repeating: StyledSpan(fg: .white, bg: .black, bold: false, text: " "), count: cols),
      count: rows
    )

    SlateChatRenderer.buildSemanticInputRows(
      &grid,
      startRow: -1,
      cols: 10,
      textWidth: 4,
      visualLines: ["hello"],
      rowCount: 1,
      inputMode: .edit,
      llmWaitAnimationFrame: 0,
      waitingForLLM: false,
      theme: theme)

    // Grid should be unchanged
    #expect(grid[0][0].text == " ")
  }
}

// MARK: - queuedTrayVisualLines / queuedTrayRowCount

/// Tests for `SlateChatRenderer.queuedTrayVisualLines` and `queuedTrayRowCount`
/// — tray wrapping, capping, and row counting with the `String?` API.
@Suite
struct SlateChatRendererQueuedTrayTests {

  // MARK: - queuedTrayVisualLines

  @Test func nilTextReturnsNoVisualLines() {
    let lines = SlateChatRenderer.queuedTrayVisualLines(queuedTrayText: nil, textWidth: 40)
    #expect(lines.isEmpty)
  }

  @Test func emptyTextReturnsNoVisualLines() {
    let lines = SlateChatRenderer.queuedTrayVisualLines(queuedTrayText: "", textWidth: 40)
    #expect(lines.isEmpty)
  }

  @Test func singleMessageWrapsToVisualLines() {
    // "abcde\nfghij" with width 5 → two logical lines
    let lines = SlateChatRenderer.queuedTrayVisualLines(
      queuedTrayText: "abcde\nfghij", textWidth: 5)
    #expect(lines.count == 2)
    #expect(lines[0] == "abcde")
    #expect(lines[1] == "fghij")
  }

  @Test func capsAtMaxTrayRows() {
    // 26 chars with width 2 → many visual lines, but capped at 4
    let lines = SlateChatRenderer.queuedTrayVisualLines(
      queuedTrayText: "abcdefghijklmnopqrstuvwxyz", textWidth: 2)
    #expect(lines.count <= 4)
    #expect(lines.count == 4)
    // Last line should have "…" truncation
    #expect(lines[3].hasSuffix("…"))
  }

  @Test func zeroTextWidthReturnsEmpty() {
    let lines = SlateChatRenderer.queuedTrayVisualLines(
      queuedTrayText: "hello", textWidth: 0)
    #expect(lines.isEmpty)
  }

  // MARK: - queuedTrayRowCount

  @Test func nilTextReturnsZeroRows() {
    let count = SlateChatRenderer.queuedTrayRowCount(queuedTrayText: nil, cols: 80)
    #expect(count == 0)
  }

  @Test func singleMessageReturnsCorrectRowCount() {
    let count = SlateChatRenderer.queuedTrayRowCount(
      queuedTrayText: "hello world", cols: 80)
    #expect(count == 1)
  }

  @Test func multiLineMessageReturnsCorrectRowCount() {
    let count = SlateChatRenderer.queuedTrayRowCount(
      queuedTrayText: "line1\nline2\nline3", cols: 80)
    #expect(count == 3)
  }

  // MARK: - buildSemanticQueuedTrayRows

  @Test func buildSemanticQueuedTrayShowsQueuedPrefix() {
    let theme = CLITheme.default
    let cols = 40
    let rows = 3
    var grid = [[StyledSpan]](
      repeating: [StyledSpan](repeating: StyledSpan(fg: .white, bg: .black, bold: false, text: " "), count: cols),
      count: rows
    )

    let paintLines = SlateChatRenderer.queuedTrayVisualLines(
      queuedTrayText: "hello", textWidth: 34)
    SlateChatRenderer.buildSemanticQueuedTrayRows(
      &grid,
      startRow: 0,
      cols: 40,
      textWidth: 34,
      visualLines: paintLines,
      theme: theme)

    // "queued: " prefix in queuedPrefix color
    let prefix = "queued: "
    for (i, ch) in prefix.enumerated() {
      #expect(grid[0][i].text == String(ch))
      #expect(grid[0][i].fg == theme.queuedPrefix)
    }
    // Message text in queuedText color
    #expect(grid[0][prefix.count].text == "h")
    #expect(grid[0][prefix.count].fg == theme.queuedText)
  }

  @Test func buildSemanticQueuedTrayContinuationRowsUseGutter() {
    let theme = CLITheme.default
    let cols = 40
    let rows = 3
    var grid = [[StyledSpan]](
      repeating: [StyledSpan](repeating: StyledSpan(fg: .white, bg: .black, bold: false, text: " "), count: cols),
      count: rows
    )

    let paintLines = SlateChatRenderer.queuedTrayVisualLines(
      queuedTrayText: "line one\nline two", textWidth: 34)
    SlateChatRenderer.buildSemanticQueuedTrayRows(
      &grid,
      startRow: 0,
      cols: 40,
      textWidth: 34,
      visualLines: paintLines,
      theme: theme)

    // Row 0: "queued: " + "line one"
    #expect(grid[0][0].text == "q")
    // Row 1: gutter spaces in queuedGutter color
    #expect(grid[1][0].text == " ")
    #expect(grid[1][0].fg == theme.queuedGutter)
  }

  @Test func buildSemanticQueuedTrayEmptyVisualLinesIsNoop() {
    let theme = CLITheme.default
    let cols = 40
    let rows = 3
    var grid = [[StyledSpan]](
      repeating: [StyledSpan](repeating: StyledSpan(fg: .white, bg: .black, bold: false, text: " "), count: cols),
      count: rows
    )

    SlateChatRenderer.buildSemanticQueuedTrayRows(
      &grid,
      startRow: 0,
      cols: 40,
      textWidth: 34,
      visualLines: [],
      theme: theme)

    // Grid should be unchanged
    #expect(grid[0][0].text == " ")
  }

  @Test func buildSemanticQueuedTrayBackgroundUsesInputAreaBg() {
    let theme = CLITheme.default
    let cols = 40
    let rows = 3
    var grid = [[StyledSpan]](
      repeating: [StyledSpan](repeating: StyledSpan(fg: .white, bg: .black, bold: false, text: " "), count: cols),
      count: rows
    )

    let paintLines = SlateChatRenderer.queuedTrayVisualLines(
      queuedTrayText: "test", textWidth: 34)
    SlateChatRenderer.buildSemanticQueuedTrayRows(
      &grid,
      startRow: 0,
      cols: 40,
      textWidth: 34,
      visualLines: paintLines,
      theme: theme)

    // "queued: " (8 chars) + "test" (4 chars) = 12 chars of content
    // The spans written by buildSemanticQueuedTrayRows use inputAreaBg background
    #expect(grid[0][0].bg == theme.inputAreaBg)
    // Position 8 is the start of "test"
    #expect(grid[0][8].bg == theme.inputAreaBg)
  }

  // MARK: - transcriptContentRows

  @Test func transcriptContentRowsAccountsForTrayRows() {
    // With nil tray text, content rows = full available space
    let withoutTray = SlateChatRenderer.transcriptContentRows(
      cols: 80, rows: 24,
      banner: nil, usage: nil,
      inputLine: "", waitingForLLM: false,
      queuedTrayText: nil)
    // With tray text that takes 2 visual rows, content rows should be 2 less
    let withTray = SlateChatRenderer.transcriptContentRows(
      cols: 80, rows: 24,
      banner: nil, usage: nil,
      inputLine: "", waitingForLLM: false,
      queuedTrayText: "line1\nline2")
    #expect(withTray == withoutTray - 2)
  }
}
