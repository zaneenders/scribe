import Foundation
import Testing
import SlateCore

@testable import ScribeCLI

// MARK: - Transcript layout + viewport + render integration tests

/// Simulates the host's render loop: transcript → flatten → viewport → render.
/// Focused on catching any gap in the first-message scenario.
@Suite
@MainActor
struct TranscriptRenderIntegrationTests {

  // MARK: - First-message: empty → non-empty transcript transition

  @Test func firstMessageFromEmptyTranscriptPaintsCorrectly() {
    let cols = 80
    let rows = 24
    let theme = CLITheme.default
    var flattenCache = TranscriptLayout.FlattenCache()
    var viewport = TranscriptViewport()
    var transcriptLines: [TLine] = []

    let banner = BannerSnapshot(
      baseURL: "https://api.example.com",
      model: "test-model",
      cwd: "/tmp",
      scribeVersion: "0.0.1",
      gitBranch: nil,
      sessionId: "test-sid"
    )

    // ── Frame 1: Empty transcript (before coordinator runs) ──
    var grid1 = TerminalCellGrid(cols: cols, rows: rows, filling: .defaultCell)
    let flat1 = TranscriptLayout.FlattenCache.flatten(
      cache: &flattenCache,
      completed: transcriptLines,
      open: nil,
      width: cols,
      generation: 0)
    let contentRows1 = SlateChatRenderer.transcriptContentRows(
      cols: cols, rows: rows, banner: banner, usage: nil,
      inputLine: "typing...", waitingForLLM: false, queuedTrayText: nil)
    _ = viewport.resolve(flatCount: flat1.count, contentRows: contentRows1)

    SlateChatRenderer.render(
      into: &grid1, cols: cols, rows: rows,
      flattenedTranscript: flat1,
      transcriptTailStart: viewport.firstVisibleRow,
      banner: banner, usage: nil,
      inputLine: "typing...",
      llmWaitAnimationFrame: 0,
      waitingForLLM: false,
      queuedTrayText: nil,
      theme: theme)

    // Verify: transcript area is blank (only background fill)
    let headerRows = 3
    let rowBelowHeader = headerRows
    #expect(grid1[column: 0, row: rowBelowHeader].glyph == " ",
      "Frame 1: transcript area should be blank")

    // ── Frame 2: User message arrives (after coordinator runs) ──
    // Simulate handleTranscriptEvent(.userSubmitted("hello"))
    transcriptLines.append(
      TLine(spans: [StyledSpan(fg: theme.userPrefix, bg: theme.background, bold: false, text: "you:")]))
    transcriptLines.append(
      TLine(spans: [StyledSpan(fg: theme.userBody, bg: theme.background, bold: false, text: "  hello")]))

    var grid2 = TerminalCellGrid(cols: cols, rows: rows, filling: .defaultCell)
    let flat2 = TranscriptLayout.FlattenCache.flatten(
      cache: &flattenCache,
      completed: transcriptLines,
      open: nil,
      width: cols,
      generation: 0)  // userSubmitted doesn't increment generation

    let contentRows2 = SlateChatRenderer.transcriptContentRows(
      cols: cols, rows: rows, banner: banner, usage: nil,
      inputLine: "", waitingForLLM: true, queuedTrayText: nil)
    _ = viewport.resolve(flatCount: flat2.count, contentRows: contentRows2)

    SlateChatRenderer.render(
      into: &grid2, cols: cols, rows: rows,
      flattenedTranscript: flat2,
      transcriptTailStart: viewport.firstVisibleRow,
      banner: banner, usage: nil,
      inputLine: "",
      llmWaitAnimationFrame: 0,
      waitingForLLM: true,
      queuedTrayText: nil,
      theme: theme)

    // The transcript area should now contain "you:" and "  hello"
    // contentRows = 20, flatCount = 2, topPad = 18, first content row = 3 + 18 = 21
    let expectedFirstContentRow = 3 + (contentRows2 - flat2.count)  // headerRows + topPad
    #expect(expectedFirstContentRow == 21)

    let youCell = grid2[column: 0, row: expectedFirstContentRow]
    #expect(youCell.glyph == "y",
      "Frame 2: Expected 'y' from 'you:' at row \(expectedFirstContentRow), got '\(youCell.glyph)'")

    let helloCell = grid2[column: 2, row: expectedFirstContentRow + 1]
    #expect(helloCell.glyph == "h",
      "Frame 2: Expected 'h' from 'hello' at row \(expectedFirstContentRow + 1) col 2, got '\(helloCell.glyph)'")
  }

  // MARK: - Viewport stays in follow mode through empty→content transition

  @Test func viewportFollowsLiveThroughFirstMessage() {
    var viewport = TranscriptViewport()

    // Empty transcript
    #expect(viewport.followingLive == true)
    let pos0 = viewport.resolve(flatCount: 0, contentRows: 20)
    #expect(pos0 == 0)
    #expect(viewport.followingLive == true)

    // User message arrives (2 lines, still fits in 20 content rows)
    let pos1 = viewport.resolve(flatCount: 2, contentRows: 20)
    #expect(pos1 == 0)  // max(0, 2-20) = 0
    #expect(viewport.followingLive == true,
      "Viewport should still be following live after first message")

    // Large transcript growth (model responds)
    let pos2 = viewport.resolve(flatCount: 100, contentRows: 20)
    #expect(pos2 == 80)  // 100 - 20
    #expect(viewport.followingLive == true)
  }

  // MARK: - FlattenCache handles empty→non-empty transition

  @Test func flattenCacheAppendsNewLines() {
    var cache = TranscriptLayout.FlattenCache()

    // First call: empty transcript
    let flat0 = TranscriptLayout.FlattenCache.flatten(
      cache: &cache, completed: [], open: nil, width: 80, generation: 0)
    #expect(flat0.isEmpty)

    // Second call: 2 lines added, same generation
    let lines: [TLine] = [
      TLine(spans: [StyledSpan(fg: .blue, bg: .black, bold: false, text: "you:")]),
      TLine(spans: [StyledSpan(fg: .white, bg: .black, bold: false, text: "  hello")]),
    ]
    let flat1 = TranscriptLayout.FlattenCache.flatten(
      cache: &cache, completed: lines, open: nil, width: 80, generation: 0)
    #expect(flat1.count == 2, "Expected 2 flattened lines, got \(flat1.count)")
    #expect(flat1[0].spans.first?.text == "you:")
    #expect(flat1[1].spans.first?.text == "  hello")
  }

  // MARK: - Generation change resets cache

  @Test func generationChangeResetsFlattenCache() {
    var cache = TranscriptLayout.FlattenCache()

    // Build up some cached content
    let lines1: [TLine] = [
      TLine(spans: [StyledSpan(fg: .blue, bg: .black, bold: false, text: "line1")]),
    ]
    _ = TranscriptLayout.FlattenCache.flatten(
      cache: &cache, completed: lines1, open: nil, width: 80, generation: 0)

    // Now generation changes (like when streaming re-renders happen)
    let lines2: [TLine] = [
      TLine(spans: [StyledSpan(fg: .blue, bg: .black, bold: false, text: "line1")]),
      TLine(spans: [StyledSpan(fg: .white, bg: .black, bold: false, text: "line2")]),
    ]
    let flat = TranscriptLayout.FlattenCache.flatten(
      cache: &cache, completed: lines2, open: nil, width: 80, generation: 1)

    // Cache should have been reset, then recomputed with the new lines
    #expect(flat.count == 2)
    #expect(flat[0].spans.first?.text == "line1")
    #expect(flat[1].spans.first?.text == "line2")
  }
}
