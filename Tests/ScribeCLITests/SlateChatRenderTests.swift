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
