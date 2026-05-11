import Foundation
import SlateCore
import Testing

@testable import ScribeCLI

// MARK: - SlateChatRenderer transcript rendering tests

/// Tests that the render pipeline correctly paints transcript content
/// for the first-message scenario and during transcript growth.
@Suite
struct SlateChatRenderTests {

  // MARK: - First message: transcript appears at the bottom

  @Test func firstUserMessageAppearsInTranscriptArea() {
    let cols = 80
    let rows = 24

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
    let grid = SlateChatRenderer.buildGrid(
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
    let span21 = grid[row21][0]
    #expect(span21.text == "y", "Expected 'y' from 'you:' at row \(row21), got '\(span21.text)'")

    let span22 = grid[row21 + 1][0]
    // Second line starts with "  hello", first char is space
    #expect(span22.text == " ", "Expected space at row \(row21 + 1), got '\(span22.text)'")
    let span22Text = grid[row21 + 1][2]
    #expect(span22Text.text == "h", "Expected 'h' from 'hello' at row \(row21 + 1), col 2, got '\(span22Text.text)'")

    // The rows above the content should be blank (transcript background fill)
    if row21 > transcriptStartRow {
      let blankSpan = grid[transcriptStartRow][0]
      #expect(blankSpan.text == " ", "Expected blank (space) at row \(transcriptStartRow), got '\(blankSpan.text)'")
    }
  }

  // MARK: - Transcript grows while following live

  @Test func transcriptGrowthTracksTail() {
    let cols = 80
    let rows = 24

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

    let grid1 = SlateChatRenderer.buildGrid(
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
    #expect(grid1[21][0].text == "y")

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

    let grid2 = SlateChatRenderer.buildGrid(
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
    let topSpan = grid2[firstContentRow][0]
    #expect(topSpan.text != "y", "Expected first message to be scrolled off, but 'y' found at row \(firstContentRow)")
  }

  // MARK: - Empty transcript renders blank area correctly

  @Test func emptyTranscriptRendersBlank() {
    let cols = 80
    let rows = 24

    let banner = BannerSnapshot(
      baseURL: "https://api.example.com",
      model: "test-model",
      cwd: "/tmp",
      scribeVersion: "0.0.1",
      gitBranch: nil,
      sessionId: "test-sid"
    )

    let grid = SlateChatRenderer.buildGrid(
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
    let span = grid[headerRows][0]
    #expect(span.text == " ", "Expected blank transcript area, got '\(span.text)' at row \(headerRows)")
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


// MARK: - SlateChatRenderer queued tray tests

@Suite
struct QueuedTrayTests {

    // MARK: - queuedTrayRowCount

    @Test func rowCountNilText() {
        #expect(SlateChatRenderer.queuedTrayRowCount(queuedTrayText: nil, cols: 80) == 0)
    }

    @Test func rowCountEmptyText() {
        #expect(SlateChatRenderer.queuedTrayRowCount(queuedTrayText: "", cols: 80) == 0)
    }

    @Test func rowCountSingleLine() {
        #expect(SlateChatRenderer.queuedTrayRowCount(queuedTrayText: "hello", cols: 80) == 1)
    }

    @Test func rowCountMultiLine() {
        #expect(SlateChatRenderer.queuedTrayRowCount(queuedTrayText: "a\nb\nc", cols: 80) == 3)
    }

    @Test func rowCountWrappedLine() {
        // A long line that wraps at width 10 (gutter=8, so textWidth=72 for cols=80)
        // "queuedTrayRowCount" has gutter 8, so for cols=18, textWidth=10
        let longLine = String(repeating: "x", count: 50)
        // At textWidth=10, 50 chars → 5 visual lines, capped at 4
        let rows = SlateChatRenderer.queuedTrayRowCount(queuedTrayText: longLine, cols: 18)
        #expect(rows > 0)
    }
}

// MARK: - SlateChatRenderer banner tests

@Suite
struct BannerRenderTests {

    @Test func buildGridWithBannerShowsLLMRow() {
        let cols = 80
        let rows = 24
        let banner = BannerSnapshot(
            baseURL: "https://api.example.com",
            model: "test-model",
            cwd: "/tmp",
            scribeVersion: "0.0.1",
            gitBranch: nil,
            sessionId: "test-sid"
        )
        let grid = SlateChatRenderer.buildGrid(
            cols: cols, rows: rows,
            flattenedTranscript: [], transcriptTailStart: 0,
            banner: banner, usage: nil,
            inputLine: "", llmWaitAnimationFrame: 0,
            waitingForLLM: false, queuedTrayText: nil,
            theme: .default
        )
        let row0Text = grid[0].map(\.text).joined()
        #expect(row0Text.contains("LLM:"))
        #expect(row0Text.contains("api.example.com"))
    }

    @Test func buildGridWithBannerShowsModelRow() {
        let cols = 80
        let rows = 24
        let banner = BannerSnapshot(
            baseURL: "https://api.example.com",
            model: "test-model",
            cwd: "/tmp",
            scribeVersion: "0.0.1",
            gitBranch: nil,
            sessionId: "test-sid"
        )
        let grid = SlateChatRenderer.buildGrid(
            cols: cols, rows: rows,
            flattenedTranscript: [], transcriptTailStart: 0,
            banner: banner, usage: nil,
            inputLine: "", llmWaitAnimationFrame: 0,
            waitingForLLM: false, queuedTrayText: nil,
            theme: .default
        )
        let row1Text = grid[1].map(\.text).joined()
        #expect(row1Text.contains("Model:"))
        #expect(row1Text.contains("test-model"))
    }

    @Test func buildGridWithBannerShowsCWDRow() {
        let cols = 80
        let rows = 24
        let banner = BannerSnapshot(
            baseURL: "https://api.example.com",
            model: "test-model",
            cwd: "/home/user/project",
            scribeVersion: "0.0.1",
            gitBranch: nil,
            sessionId: "test-sid"
        )
        let grid = SlateChatRenderer.buildGrid(
            cols: cols, rows: rows,
            flattenedTranscript: [], transcriptTailStart: 0,
            banner: banner, usage: nil,
            inputLine: "", llmWaitAnimationFrame: 0,
            waitingForLLM: false, queuedTrayText: nil,
            theme: .default
        )
        let row2Text = grid[2].map(\.text).joined()
        #expect(row2Text.contains("CWD:"))
        #expect(row2Text.contains("/home/user/project"))
    }

    @Test func bannerWithGitBranchShowsBranch() {
        let cols = 80
        let rows = 24
        let banner = BannerSnapshot(
            baseURL: "https://api.example.com",
            model: "test-model",
            cwd: "/tmp",
            scribeVersion: "0.0.1",
            gitBranch: "main",
            sessionId: "test-sid"
        )
        let grid = SlateChatRenderer.buildGrid(
            cols: cols, rows: rows,
            flattenedTranscript: [], transcriptTailStart: 0,
            banner: banner, usage: nil,
            inputLine: "", llmWaitAnimationFrame: 0,
            waitingForLLM: false, queuedTrayText: nil,
            theme: .default
        )
        let row2Text = grid[2].map(\.text).joined()
        #expect(row2Text.contains("@main"))
    }

    @Test func tinyTerminalNoBannerRows() {
        let cols = 40
        let rows = 1
        let banner = BannerSnapshot(
            baseURL: "u", model: "m", cwd: "/",
            scribeVersion: "v", gitBranch: nil, sessionId: "s"
        )
        let grid = SlateChatRenderer.buildGrid(
            cols: cols, rows: rows,
            flattenedTranscript: [], transcriptTailStart: 0,
            banner: banner, usage: nil,
            inputLine: "", llmWaitAnimationFrame: 0,
            waitingForLLM: false, queuedTrayText: nil,
            theme: .default
        )
        #expect(grid.count == 1)
        #expect(grid[0].count == 40)
    }
}

// MARK: - SlateChatRenderer usage HUD tests

@Suite
struct UsageHUDRenderTests {

    @Test func buildGridWithUsageShowsHUD() {
        let cols = 80
        let rows = 24
        let usage = UsageHUDSnapshot(
            roundPrompt: 500, roundCompletion: 200, roundTotal: 700,
            turnPrompt: 1500, turnCompletion: 800, turnTotal: 2300,
            sessionPrompt: 5000, sessionCompletion: 3000, sessionTotal: 8000,
            reasoningTokens: nil, cachedPromptTokens: nil,
            outputTokensPerSecond: nil, contextWindow: nil, contextWindowUsedPercent: nil
        )
        let grid = SlateChatRenderer.buildGrid(
            cols: cols, rows: rows,
            flattenedTranscript: [], transcriptTailStart: 0,
            banner: nil, usage: usage,
            inputLine: "", llmWaitAnimationFrame: 0,
            waitingForLLM: false, queuedTrayText: nil,
            theme: .default
        )
        let topRight = grid[0][cols - 1].text
        #expect(!topRight.isEmpty)
    }

    @Test func usageHUDWithContextWindowPercentShowsPct() {
        let cols = 100
        let rows = 24
        let usage = UsageHUDSnapshot(
            roundPrompt: 1000, roundCompletion: 500, roundTotal: 1500,
            turnPrompt: 3000, turnCompletion: 1500, turnTotal: 4500,
            sessionPrompt: 10000, sessionCompletion: 5000, sessionTotal: 15000,
            reasoningTokens: nil, cachedPromptTokens: nil,
            outputTokensPerSecond: 42.5, contextWindow: 128000, contextWindowUsedPercent: 85
        )
        let grid = SlateChatRenderer.buildGrid(
            cols: cols, rows: rows,
            flattenedTranscript: [], transcriptTailStart: 0,
            banner: nil, usage: usage,
            inputLine: "", llmWaitAnimationFrame: 0,
            waitingForLLM: false, queuedTrayText: nil,
            theme: .default
        )
        let hudText = grid[0].map(\.text).joined()
        #expect(hudText.contains("85%"))
        #expect(hudText.contains("42.5/s"))
    }

    @Test func usageHUDWithReasoningTokens() {
        let cols = 100
        let rows = 24
        let usage = UsageHUDSnapshot(
            roundPrompt: 100, roundCompletion: 50, roundTotal: 150,
            turnPrompt: 200, turnCompletion: 100, turnTotal: 300,
            sessionPrompt: 500, sessionCompletion: 300, sessionTotal: 800,
            reasoningTokens: 120, cachedPromptTokens: nil,
            outputTokensPerSecond: nil, contextWindow: nil, contextWindowUsedPercent: nil
        )
        let grid = SlateChatRenderer.buildGrid(
            cols: cols, rows: rows,
            flattenedTranscript: [], transcriptTailStart: 0,
            banner: nil, usage: usage,
            inputLine: "", llmWaitAnimationFrame: 0,
            waitingForLLM: false, queuedTrayText: nil,
            theme: .default
        )
        let row1Text = grid[1].map(\.text).joined()
        #expect(row1Text.contains("reasoning"))
    }

    @Test func usageHUDWithCachedPromptTokens() {
        let cols = 100
        let rows = 24
        let usage = UsageHUDSnapshot(
            roundPrompt: 100, roundCompletion: 50, roundTotal: 150,
            turnPrompt: 200, turnCompletion: 100, turnTotal: 300,
            sessionPrompt: 500, sessionCompletion: 300, sessionTotal: 800,
            reasoningTokens: nil, cachedPromptTokens: 75,
            outputTokensPerSecond: nil, contextWindow: nil, contextWindowUsedPercent: nil
        )
        let grid = SlateChatRenderer.buildGrid(
            cols: cols, rows: rows,
            flattenedTranscript: [], transcriptTailStart: 0,
            banner: nil, usage: usage,
            inputLine: "", llmWaitAnimationFrame: 0,
            waitingForLLM: false, queuedTrayText: nil,
            theme: .default
        )
        let row1Text = grid[1].map(\.text).joined()
        #expect(row1Text.contains("cache"))
    }
}

// MARK: - SlateChatRenderer spinner tests

@Suite
struct SpinnerRenderTests {

    @Test func buildGridShowsSpinnerWhenWaitingAndEmptyInput() {
        let cols = 80
        let rows = 24
        let grid = SlateChatRenderer.buildGrid(
            cols: cols, rows: rows,
            flattenedTranscript: [], transcriptTailStart: 0,
            banner: nil, usage: nil,
            inputLine: "", llmWaitAnimationFrame: 0,
            waitingForLLM: true, queuedTrayText: nil,
            theme: .default
        )
        let inputRow = rows - 1
        let inputText = grid[inputRow].map(\.text).joined()
        #expect(inputText.contains("scribe:"))
    }

    @Test func spinnerAdvancesWithFrame() {
        let cols = 80
        let rows = 24
        let grid0 = SlateChatRenderer.buildGrid(
            cols: cols, rows: rows,
            flattenedTranscript: [], transcriptTailStart: 0,
            banner: nil, usage: nil,
            inputLine: "", llmWaitAnimationFrame: 0,
            waitingForLLM: true, queuedTrayText: nil,
            theme: .default
        )
        let grid1 = SlateChatRenderer.buildGrid(
            cols: cols, rows: rows,
            flattenedTranscript: [], transcriptTailStart: 0,
            banner: nil, usage: nil,
            inputLine: "", llmWaitAnimationFrame: 1,
            waitingForLLM: true, queuedTrayText: nil,
            theme: .default
        )
        let inputRow = rows - 1
        let text0 = grid0[inputRow].map(\.text).joined()
        let text1 = grid1[inputRow].map(\.text).joined()
        #expect(text0 != text1)
    }

    @Test func noSpinnerWhenNotWaiting() {
        let cols = 80
        let rows = 24
        let grid = SlateChatRenderer.buildGrid(
            cols: cols, rows: rows,
            flattenedTranscript: [], transcriptTailStart: 0,
            banner: nil, usage: nil,
            inputLine: "typing...", llmWaitAnimationFrame: 0,
            waitingForLLM: false, queuedTrayText: nil,
            theme: .default
        )
        let inputRow = rows - 1
        let inputText = grid[inputRow].map(\.text).joined()
        #expect(inputText.contains("you:"))
        #expect(!inputText.contains("scribe:"))
    }
}

// MARK: - SlateChatRenderer queued tray in grid tests

@Suite
struct QueuedTrayGridTests {

    @Test func buildGridWithQueuedTrayShowsQueuedPrefix() {
        let cols = 80
        let rows = 24
        let grid = SlateChatRenderer.buildGrid(
            cols: cols, rows: rows,
            flattenedTranscript: [], transcriptTailStart: 0,
            banner: nil, usage: nil,
            inputLine: "", llmWaitAnimationFrame: 0,
            waitingForLLM: true, queuedTrayText: "fix the bug",
            theme: .default
        )
        let trayRow = rows - 2
        let trayText = grid[trayRow].map(\.text).joined()
        #expect(trayText.contains("queued:"))
    }
}

// MARK: - TranscriptLayout.flattenedRows edge case tests

@Suite
struct FlattenedRowsEdgeCaseTests {

    @Test func zeroWidthReturnsEmpty() {
        let lines: [TLine] = [
            TLine(spans: [StyledSpan(fg: .white, bg: .black, bold: false, text: "hello")])
        ]
        let result = TranscriptLayout.flattenedRows(from: lines, width: 0)
        #expect(result.isEmpty)
    }

    @Test func emptySpansProducesBlankLine() {
        let lines: [TLine] = [TLine(spans: [])]
        let result = TranscriptLayout.flattenedRows(from: lines, width: 80)
        #expect(result.count == 1)
        #expect(result[0].spans.isEmpty)
    }

    @Test func spansWithNewlinesAreSplit() {
        let lines: [TLine] = [
            TLine(spans: [
                StyledSpan(fg: .white, bg: .black, bold: false, text: "line1\nline2")
            ])
        ]
        let result = TranscriptLayout.flattenedRows(from: lines, width: 80)
        #expect(result.count == 2)
        #expect(result[0].spans.first?.text == "line1")
        #expect(result[1].spans.first?.text == "line2")
    }

    @Test func consecutiveNewlinesProduceBlankLines() {
        let lines: [TLine] = [
            TLine(spans: [
                StyledSpan(fg: .white, bg: .black, bold: false, text: "a\n\nb")
            ])
        ]
        let result = TranscriptLayout.flattenedRows(from: lines, width: 80)
        #expect(result.count == 3)
        #expect(result[0].spans.first?.text == "a")
        #expect(result[1].spans.isEmpty)
        #expect(result[2].spans.first?.text == "b")
    }

    @Test func longWordSplitsAcrossLines() {
        let lines: [TLine] = [
            TLine(spans: [
                StyledSpan(fg: .white, bg: .black, bold: false, text: "abcdefghijklmnop")
            ])
        ]
        let result = TranscriptLayout.flattenedRows(from: lines, width: 5)
        #expect(result.count == 4)
        #expect(result[0].spans.first?.text == "abcde")
        #expect(result[1].spans.first?.text == "fghij")
        #expect(result[2].spans.first?.text == "klmno")
        #expect(result[3].spans.first?.text == "p")
    }

    @Test func mixedShortAndLongTokensWrapCorrectly() {
        let lines: [TLine] = [
            TLine(spans: [
                StyledSpan(fg: .white, bg: .black, bold: false, text: "hi there world")
            ])
        ]
        let result = TranscriptLayout.flattenedRows(from: lines, width: 8)
        #expect(result.count == 2)
        #expect(result[0].spans.first?.text == "hi there")
        #expect(result[1].spans.first?.text == " world")
    }

    @Test func spanStylePreservedAcrossWraps() {
        let lines: [TLine] = [
            TLine(spans: [
                StyledSpan(fg: .red, bg: .black, bold: true, text: "abcdefghij")
            ])
        ]
        let result = TranscriptLayout.flattenedRows(from: lines, width: 4)
        #expect(result.count == 3)
        for line in result {
            for span in line.spans {
                #expect(span.bold == true)
                #expect(span.fg == .red)
            }
        }
    }

    // MARK: - width=1 edge cases

    @Test func widthOneSplitsEveryCharacter() {
        let lines: [TLine] = [
            TLine(spans: [
                StyledSpan(fg: .white, bg: .black, bold: false, text: "abc")
            ])
        ]
        let result = TranscriptLayout.flattenedRows(from: lines, width: 1)
        #expect(result.count == 3)
        #expect(result[0].spans.first?.text == "a")
        #expect(result[1].spans.first?.text == "b")
        #expect(result[2].spans.first?.text == "c")
    }

    @Test func widthOneWithNewline() {
        let lines: [TLine] = [
            TLine(spans: [
                StyledSpan(fg: .white, bg: .black, bold: false, text: "a\nb")
            ])
        ]
        let result = TranscriptLayout.flattenedRows(from: lines, width: 1)
        #expect(result.count == 2)
        #expect(result[0].spans.first?.text == "a")
        #expect(result[1].spans.first?.text == "b")
    }

    @Test func widthOneSingleCharacter() {
        let lines: [TLine] = [
            TLine(spans: [
                StyledSpan(fg: .white, bg: .black, bold: false, text: "x")
            ])
        ]
        let result = TranscriptLayout.flattenedRows(from: lines, width: 1)
        #expect(result.count == 1)
        #expect(result[0].spans.first?.text == "x")
    }
}

// MARK: - transcriptContentRows edge case tests

@Suite
struct TranscriptContentRowsEdgeCaseTests {

    @Test func withBannerAndUsageAndQueuedTray() {
        let banner = BannerSnapshot(
            baseURL: "http://api", model: "m", cwd: "/",
            scribeVersion: "v", gitBranch: nil, sessionId: "s")
        let usage = UsageHUDSnapshot(
            roundPrompt: 100, roundCompletion: 50, roundTotal: 150,
            turnPrompt: 200, turnCompletion: 100, turnTotal: 300,
            sessionPrompt: 500, sessionCompletion: 300, sessionTotal: 800,
            reasoningTokens: nil, cachedPromptTokens: nil,
            outputTokensPerSecond: nil, contextWindow: nil, contextWindowUsedPercent: nil)
        let rows = SlateChatRenderer.transcriptContentRows(
            cols: 80, rows: 24, banner: banner, usage: usage,
            inputLine: "hello", waitingForLLM: false,
            queuedTrayText: "pending work")
        // headerRows = 3 (banner), tray row, input row = 24-3-1-1 = 19 left for content
        #expect(rows > 0)
    }

    @Test func tinyTerminalReturnsZeroContentRows() {
        // rows=3: 3 header (banner), no room for content
        let banner = BannerSnapshot(
            baseURL: "u", model: "m", cwd: "/",
            scribeVersion: "v", gitBranch: nil, sessionId: "s")
        let rows = SlateChatRenderer.transcriptContentRows(
            cols: 10, rows: 3, banner: banner, usage: nil,
            inputLine: "", waitingForLLM: false,
            queuedTrayText: nil)
        #expect(rows == 0)
    }

    @Test func exactlyOneContentRow() {
        // rows=5: 3 header, 1 tray, 1 input = 0 content rows
        // Actually let's do: rows=5, no tray, no spinner, short input
        let banner = BannerSnapshot(
            baseURL: "u", model: "m", cwd: "/",
            scribeVersion: "v", gitBranch: nil, sessionId: "s")
        let rows = SlateChatRenderer.transcriptContentRows(
            cols: 80, rows: 5, banner: banner, usage: nil,
            inputLine: "x", waitingForLLM: false,
            queuedTrayText: nil)
        #expect(rows == 1) // 5 - 3 header - 1 input = 1 content
    }

    @Test func noBannerNoUsageNoTray() {
        let rows = SlateChatRenderer.transcriptContentRows(
            cols: 80, rows: 24, banner: nil, usage: nil,
            inputLine: "hello", waitingForLLM: false,
            queuedTrayText: nil)
        // No header, 1 input row -> 23 content rows
        #expect(rows == 23)
    }

    @Test func waitingForLLMNoInputHasSpinner() {
        let rows = SlateChatRenderer.transcriptContentRows(
            cols: 80, rows: 24, banner: nil, usage: nil,
            inputLine: "", waitingForLLM: true,
            queuedTrayText: nil)
        // spinner takes 1 row, no header -> 23 content rows
        #expect(rows == 23)
    }
}

// MARK: - buildGrid with banner and usage HUD simultaneously

@Suite
struct BuildGridBannerAndUsageTests {

    @Test func buildGridWithBannerAndUsage() {
        let cols = 100
        let rows = 24
        let banner = BannerSnapshot(
            baseURL: "https://api.example.com",
            model: "test-model",
            cwd: "/home/user/project",
            scribeVersion: "0.0.1",
            gitBranch: "feature/foo",
            sessionId: "test-sid")
        let usage = UsageHUDSnapshot(
            roundPrompt: 500, roundCompletion: 200, roundTotal: 700,
            turnPrompt: 1500, turnCompletion: 800, turnTotal: 2300,
            sessionPrompt: 5000, sessionCompletion: 3000, sessionTotal: 8000,
            reasoningTokens: nil, cachedPromptTokens: nil,
            outputTokensPerSecond: nil, contextWindow: nil, contextWindowUsedPercent: nil)
        let grid = SlateChatRenderer.buildGrid(
            cols: cols, rows: rows,
            flattenedTranscript: [], transcriptTailStart: 0,
            banner: banner, usage: usage,
            inputLine: "", llmWaitAnimationFrame: 0,
            waitingForLLM: false, queuedTrayText: nil,
            theme: .default)
        // Should have banner in row 0 and usage HUD also in top-right
        #expect(grid.count == 24)
        let row0Text = grid[0].map(\.text).joined()
        #expect(row0Text.contains("LLM:"))
        #expect(row0Text.contains("api.example.com"))
        // Usage HUD text should appear in the top right
        let topRight = grid[0][cols - 1].text
        #expect(!topRight.isEmpty)
    }

    @Test func buildGridWithQueuedTrayAndSpinner() {
        let cols = 80
        let rows = 24
        let grid = SlateChatRenderer.buildGrid(
            cols: cols, rows: rows,
            flattenedTranscript: [], transcriptTailStart: 0,
            banner: nil, usage: nil,
            inputLine: "", llmWaitAnimationFrame: 0,
            waitingForLLM: true, queuedTrayText: "pending task",
            theme: .default)
        // Spinner row should show scribe: prefix, queued tray above it
        let inputRow = rows - 1
        let inputText = grid[inputRow].map(\.text).joined()
        #expect(inputText.contains("scribe:"))
        let trayRow = rows - 2
        let trayText = grid[trayRow].map(\.text).joined()
        #expect(trayText.contains("queued:"))
    }
}
