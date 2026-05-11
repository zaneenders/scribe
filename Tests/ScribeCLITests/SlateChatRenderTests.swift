import Foundation
import SlateCore
import Testing

@testable import ScribeCLI

// MARK: - SlateChatRenderer transcript rendering tests

/// Tests that the render pipeline correctly paints transcript content
/// for the first-message scenario and during transcript growth.
@Suite
@MainActor
struct SlateChatRenderTests {

  // MARK: - First message: transcript appears at the bottom

  @Test func firstUserMessageAppearsInTranscriptArea() {
    let cols = 80
    let rows = 24
    var grid = TerminalCellGrid(cols: cols, rows: rows, filling: .defaultCell)

    // Simulate: user submitted "hello", model becomes busy
    let transcriptLines: [TLine] = [
      TLine(spans: [
        StyledSpan(fg: .blue, bg: .black, bold: false, text: "you:")
      ]),
      TLine(spans: [
        StyledSpan(fg: .white, bg: .black, bold: false, text: "  hello")
      ]),
    ]
    let flatTranscript = TranscriptLayout.flattenedRows(
      from: transcriptLines, width: cols)

    let banner = BannerSnapshot(
      baseURL: "https://api.example.com",
      model: "test-model",
      cwd: "/tmp",
      scribeVersion: "0.0.1",
      gitBranch: nil,
      sessionId: "test-sid"
    )

    // Important: modelBusy = true, inputLine = "" (buffer taken after submit)
    SlateChatRenderer.render(
      into: &grid,
      cols: cols,
      rows: rows,
      flattenedTranscript: flatTranscript,
      transcriptTailStart: 0,  // followingLive=true with small content
      banner: banner,
      usage: nil,
      inputLine: "",
      llmWaitAnimationFrame: 0,
      waitingForLLM: true,
      queuedTrayText: nil,
      theme: .default
    )

    // The transcript area should contain "you:" and "  hello".
    // With 3 header rows, 1 input row, 20 content rows, 2 visible lines:
    // topPad = 20 - 2 = 18, so content starts at row 3+18 = 21.
    let transcriptStartRow = 3  // headerRows

    // Check that rows 21-22 contain our transcript content
    let row21 = transcriptStartRow + 18  // headerRows + topPad
    let cell21 = grid[column: 0, row: row21]
    #expect(cell21.glyph == "y", "Expected 'y' from 'you:' at row \(row21), got '\(cell21.glyph)'")

    let cell22 = grid[column: 0, row: row21 + 1]
    // Second line starts with "  hello", first char is space
    #expect(cell22.glyph == " ", "Expected space at row \(row21 + 1), got '\(cell22.glyph)'")
    let cell22Text = grid[column: 2, row: row21 + 1]
    #expect(cell22Text.glyph == "h", "Expected 'h' from 'hello' at row \(row21 + 1), col 2, got '\(cell22Text.glyph)'")

    // The rows above the content should be blank (transcript background fill)
    if row21 > transcriptStartRow {
      let blankRow = transcriptStartRow
      let blankCell = grid[column: 0, row: blankRow]
      #expect(blankCell.glyph == " ", "Expected blank (space) at row \(blankRow), got '\(blankCell.glyph)'")
    }
  }

  // MARK: - Transcript grows while following live

  @Test func transcriptGrowthTracksTail() {
    let cols = 80
    let rows = 24
    var grid = TerminalCellGrid(cols: cols, rows: rows, filling: .defaultCell)

    let banner = BannerSnapshot(
      baseURL: "https://api.example.com",
      model: "test-model",
      cwd: "/tmp",
      scribeVersion: "0.0.1",
      gitBranch: nil,
      sessionId: "test-sid"
    )

    // First frame: just the user message
    let lines1: [TLine] = [
      TLine(spans: [StyledSpan(fg: .blue, bg: .black, bold: false, text: "you:")]),
      TLine(spans: [StyledSpan(fg: .white, bg: .black, bold: false, text: "  hello")]),
    ]
    let flat1 = TranscriptLayout.flattenedRows(from: lines1, width: cols)

    SlateChatRenderer.render(
      into: &grid,
      cols: cols,
      rows: rows,
      flattenedTranscript: flat1,
      transcriptTailStart: 0,
      banner: banner,
      usage: nil,
      inputLine: "",
      llmWaitAnimationFrame: 0,
      waitingForLLM: true,
      queuedTrayText: nil,
      theme: .default
    )

    // Verify first message is visible
    #expect(grid[column: 0, row: 21].glyph == "y")

    // Now the assistant responds — transcript grows to many lines
    var lines2 = lines1
    // Add a scribe response
    lines2.append(TLine(spans: [StyledSpan(fg: .green, bg: .black, bold: false, text: "scribe:")]))
    lines2.append(TLine(spans: [StyledSpan(fg: .green, bg: .black, bold: false, text: "  · answer")]))
    for i in 0..<30 {
      lines2.append(TLine(spans: [StyledSpan(fg: .white, bg: .black, bold: false, text: "response line \(i)")]))
    }
    let flat2 = TranscriptLayout.flattenedRows(from: lines2, width: cols)

    // Viewport follows live: transcriptTailStart = max(0, flatCount - contentRows)
    // contentRows = 20, flatCount = lots
    let tailStart = max(0, flat2.count - 20)

    SlateChatRenderer.render(
      into: &grid,
      cols: cols,
      rows: rows,
      flattenedTranscript: flat2,
      transcriptTailStart: tailStart,  // following live
      banner: banner,
      usage: nil,
      inputLine: "",
      llmWaitAnimationFrame: 0,
      waitingForLLM: true,
      queuedTrayText: nil,
      theme: .default
    )

    // The bottom of the transcript area should show the last lines, not the first
    // First content row is headerRows (3). Should show tail of transcript.
    let firstContentRow = 3
    // Should NOT be "you:" at the top (that's scrolled off)
    let topCell = grid[column: 0, row: firstContentRow]
    #expect(topCell.glyph != "y", "Expected first message to be scrolled off, but 'y' found at row \(firstContentRow)")
  }

  // MARK: - Empty transcript renders blank area correctly

  @Test func emptyTranscriptRendersBlank() {
    let cols = 80
    let rows = 24
    var grid = TerminalCellGrid(cols: cols, rows: rows, filling: .defaultCell)

    let banner = BannerSnapshot(
      baseURL: "https://api.example.com",
      model: "test-model",
      cwd: "/tmp",
      scribeVersion: "0.0.1",
      gitBranch: nil,
      sessionId: "test-sid"
    )

    SlateChatRenderer.render(
      into: &grid,
      cols: cols,
      rows: rows,
      flattenedTranscript: [],
      transcriptTailStart: 0,
      banner: banner,
      usage: nil,
      inputLine: "typing...",
      llmWaitAnimationFrame: 0,
      waitingForLLM: false,
      queuedTrayText: nil,
      theme: .default
    )

    // Transcript area below header should be blank (filled with spaces)
    let headerRows = 3
    let firstBlankRow = headerRows
    let cell = grid[column: 0, row: firstBlankRow]
    #expect(cell.glyph == " ", "Expected blank transcript area, got '\(cell.glyph)' at row \(firstBlankRow)")
  }
}

// MARK: - TranscriptLayout.inputVisualLines tests

/// Tests for `TranscriptLayout.inputVisualLines` — the pure function that splits
/// a multi-line input buffer into visual lines for the input area.
///
/// The function must:
/// - Split the buffer on `\n` into logical lines
/// - Word-wrap each logical line at the given text width
/// - Return a flat array of visual rows (order = top-to-bottom as rendered)
@Suite
struct InputVisualLinesTests {

  // MARK: - Empty / zero-width

  @Test func emptyBufferReturnsSingleEmptyLine() {
    let lines = TranscriptLayout.inputVisualLines(from: "", textWidth: 80)
    #expect(lines == [""])
  }

  @Test func zeroWidthReturnsSingleEmptyLineForEmptyBuffer() {
    let lines = TranscriptLayout.inputVisualLines(from: "", textWidth: 0)
    #expect(lines == [""])
  }

  @Test func zeroWidthReturnsEmptyForNonEmptyBuffer() {
    let lines = TranscriptLayout.inputVisualLines(from: "hello", textWidth: 0)
    #expect(lines == [])
  }

  // MARK: - Single line (no newlines)

  @Test func singleShortLine() {
    let lines = TranscriptLayout.inputVisualLines(from: "hello", textWidth: 80)
    #expect(lines == ["hello"])
  }

  @Test func singleLineExactlyAtWidth() {
    let lines = TranscriptLayout.inputVisualLines(from: "12345", textWidth: 5)
    #expect(lines == ["12345"])
  }

  @Test func singleLineWrapsAtWidth() {
    // character-level: "hello " (6) + "world" (5)
    let lines = TranscriptLayout.inputVisualLines(from: "hello world", textWidth: 6)
    #expect(lines == ["hello ", "world"])
  }

  @Test func singleLongWordSplitsByWidth() {
    let lines = TranscriptLayout.inputVisualLines(from: "abcdefghij", textWidth: 3)
    #expect(lines == ["abc", "def", "ghi", "j"])
  }

  // MARK: - Multi-line from newlines

  @Test func multipleLinesPreserveNewlineSplits() {
    let lines = TranscriptLayout.inputVisualLines(from: "line1\nline2\nline3", textWidth: 80)
    #expect(lines == ["line1", "line2", "line3"])
  }

  @Test func trailingNewlineProducesEmptyFinalLine() {
    let lines = TranscriptLayout.inputVisualLines(from: "hello\n", textWidth: 80)
    #expect(lines == ["hello", ""])
  }

  @Test func leadingNewlineProducesEmptyFirstLine() {
    let lines = TranscriptLayout.inputVisualLines(from: "\nworld", textWidth: 80)
    #expect(lines == ["", "world"])
  }

  @Test func consecutiveNewlinesProduceEmptyLinesBetween() {
    let lines = TranscriptLayout.inputVisualLines(from: "a\n\nb", textWidth: 80)
    #expect(lines == ["a", "", "b"])
  }

  @Test func onlyNewlinesProducesEmptyLines() {
    let lines = TranscriptLayout.inputVisualLines(from: "\n\n", textWidth: 80)
    #expect(lines == ["", "", ""])
  }

  // MARK: - Multi-line with wrapping

  @Test func multiLineWithWrapping() {
    // Character-level wrapping: each logical line split every 6 characters
    // "abcdef ghijkl" → "abcdef", " ghijk", "l"
    // "mnopqr stuvwx" → "mnopqr", " stuvw", "x"
    let lines = TranscriptLayout.inputVisualLines(from: "abcdef ghijkl\nmnopqr stuvwx", textWidth: 6)
    #expect(lines == ["abcdef", " ghijk", "l", "mnopqr", " stuvw", "x"])
  }

  @Test func mixedShortAndWrappedLines() {
    // Character-level wrapping at width 20:
    // "this is a longer line that wraps" (35 chars)
    // → "this is a longer lin" (20) + "e that wraps" (15)
    let lines = TranscriptLayout.inputVisualLines(from: "short\nthis is a longer line that wraps", textWidth: 20)
    #expect(lines == [
      "short",
      "this is a longer lin",
      "e that wraps",
    ])
  }

  // MARK: - Whitespace handling

  @Test func leadingWhitespaceOnLogicalLineIsPreserved() {
    let lines = TranscriptLayout.inputVisualLines(from: "  indented", textWidth: 80)
    #expect(lines == ["  indented"])
  }

  @Test func multiLineWithIndentation() {
    let buffer = "  func foo() {\n    bar()\n  }"
    let lines = TranscriptLayout.inputVisualLines(from: buffer, textWidth: 80)
    #expect(lines == ["  func foo() {", "    bar()", "  }"])
  }

  // MARK: - Pass-through invariant: visual wrapping is lossless

  @Test func visualWrappingPreservesOriginalContent() {
    // The visual lines joined together (without any separator) should
    // equal the original buffer with newlines removed, since wrapping
    // is purely visual — it doesn't drop or rearrange characters.
    let buffer = "line1\nline2 that is quite long and wraps\nline3"
    let lines = TranscriptLayout.inputVisualLines(from: buffer, textWidth: 12)
    let reconstructed = lines.joined()
    let expected = buffer.replacingOccurrences(of: "\n", with: "")
    #expect(reconstructed == expected)
  }
}
