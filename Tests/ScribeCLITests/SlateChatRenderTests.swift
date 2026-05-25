import Foundation
import SlateCore
import Testing

@testable import ScribeCLI

@Suite
struct SlateChatRenderTests {

  @Test func firstUserMessageAppearsInTranscriptArea() {
    let cols = 80
    let rows = 24

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

    let grid = SlateChatRenderer.buildGrid(
      cols: cols,
      rows: rows,
      flattenedTranscript: flatTranscript,
      transcriptTailStart: 0,
      banner: banner,
      usage: nil,
      inputLine: "",
      inputMode: .edit,
      llmWaitAnimationFrame: 0,
      waitingForLLM: true,
      queuedTraySnapshot: QueuedTraySnapshot(),
      theme: .default
    )

    let transcriptStartRow = 3

    let row21 = transcriptStartRow + 18
    let span21 = grid[row21][0]
    #expect(span21.text == "y", "Expected 'y' from 'you:' at row \(row21), got '\(span21.text)'")

    let span22 = grid[row21 + 1][0]

    #expect(span22.text == " ", "Expected space at row \(row21 + 1), got '\(span22.text)'")
    let span22Text = grid[row21 + 1][2]
    #expect(span22Text.text == "h", "Expected 'h' from 'hello' at row \(row21 + 1), col 2, got '\(span22Text.text)'")

    if row21 > transcriptStartRow {
      let blankSpan = grid[transcriptStartRow][0]
      #expect(blankSpan.text == " ", "Expected blank (space) at row \(transcriptStartRow), got '\(blankSpan.text)'")
    }
  }

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
      inputMode: .edit,
      llmWaitAnimationFrame: 0,
      waitingForLLM: true,
      queuedTraySnapshot: QueuedTraySnapshot(),
      theme: .default
    )

    #expect(grid1[21][0].text == "y")

    var lines2 = lines1

    lines2.append(TLine(spans: [StyledSpan(fg: .green, bg: .black, bold: false, text: "scribe:")]))
    lines2.append(TLine(spans: [StyledSpan(fg: .green, bg: .black, bold: false, text: "  · answer")]))
    for i in 0..<30 {
      lines2.append(TLine(spans: [StyledSpan(fg: .white, bg: .black, bold: false, text: "response line \(i)")]))
    }
    let flat2 = TranscriptLayout.flattenedRows(from: lines2, width: cols)

    let tailStart = max(0, flat2.count - 20)

    let grid2 = SlateChatRenderer.buildGrid(
      cols: cols,
      rows: rows,
      flattenedTranscript: flat2,
      transcriptTailStart: tailStart,
      banner: banner,
      usage: nil,
      inputLine: "",
      inputMode: .edit,
      llmWaitAnimationFrame: 0,
      waitingForLLM: true,
      queuedTraySnapshot: QueuedTraySnapshot(),
      theme: .default
    )

    let firstContentRow = 3

    let topSpan = grid2[firstContentRow][0]
    #expect(topSpan.text != "y", "Expected first message to be scrolled off, but 'y' found at row \(firstContentRow)")
  }

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
      inputMode: .edit,
      llmWaitAnimationFrame: 0,
      waitingForLLM: false,
      queuedTraySnapshot: QueuedTraySnapshot(),
      theme: .default
    )

    let headerRows = 3
    let span = grid[headerRows][0]
    #expect(span.text == " ", "Expected blank transcript area, got '\(span.text)' at row \(headerRows)")
  }
}

@Suite
struct InputVisualLinesTests {

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

  @Test func singleShortLine() {
    let lines = TranscriptLayout.inputVisualLines(from: "hello", textWidth: 80)
    #expect(lines == ["hello"])
  }

  @Test func singleLineExactlyAtWidth() {
    let lines = TranscriptLayout.inputVisualLines(from: "12345", textWidth: 5)
    #expect(lines == ["12345"])
  }

  @Test func singleLineWrapsAtWidth() {

    let lines = TranscriptLayout.inputVisualLines(from: "hello world", textWidth: 6)
    #expect(lines == ["hello ", "world"])
  }

  @Test func singleLongWordSplitsByWidth() {
    let lines = TranscriptLayout.inputVisualLines(from: "abcdefghij", textWidth: 3)
    #expect(lines == ["abc", "def", "ghi", "j"])
  }

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

  @Test func multiLineWithWrapping() {

    let lines = TranscriptLayout.inputVisualLines(from: "abcdef ghijkl\nmnopqr stuvwx", textWidth: 6)
    #expect(lines == ["abcdef", " ghijk", "l", "mnopqr", " stuvw", "x"])
  }

  @Test func mixedShortAndWrappedLines() {

    let lines = TranscriptLayout.inputVisualLines(from: "short\nthis is a longer line that wraps", textWidth: 20)
    #expect(
      lines == [
        "short",
        "this is a longer lin",
        "e that wraps",
      ])
  }

  @Test func leadingWhitespaceOnLogicalLineIsPreserved() {
    let lines = TranscriptLayout.inputVisualLines(from: "  indented", textWidth: 80)
    #expect(lines == ["  indented"])
  }

  @Test func multiLineWithIndentation() {
    let buffer = "  func foo() {\n    bar()\n  }"
    let lines = TranscriptLayout.inputVisualLines(from: buffer, textWidth: 80)
    #expect(lines == ["  func foo() {", "    bar()", "  }"])
  }

  @Test func visualWrappingPreservesOriginalContent() {

    let buffer = "line1\nline2 that is quite long and wraps\nline3"
    let lines = TranscriptLayout.inputVisualLines(from: buffer, textWidth: 12)
    let reconstructed = lines.joined()
    let expected = buffer.replacingOccurrences(of: "\n", with: "")
    #expect(reconstructed == expected)
  }
}
