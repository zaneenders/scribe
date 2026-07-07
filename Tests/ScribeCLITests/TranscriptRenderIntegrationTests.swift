import Foundation
import SlateCore
import Testing

@testable import ScribeCLI

@Suite
@MainActor
struct TranscriptRenderIntegrationTests {

  @Test func firstMessageFromEmptyTranscriptPaintsCorrectly() {
    let cols = 80
    let rows = 24
    let theme = CLITheme.default
    var flattenCache = TranscriptLayout.FlattenCache()
    var viewport = TranscriptViewport()
    var transcriptLines: [TLine] = []

    let banner = BannerSnapshot(
      profileName: "test",
      baseURL: "https://api.example.com",
      model: "test-model",
      cwd: "/tmp",
      scribeVersion: "0.0.1",
      gitBranch: nil,
      sessionId: "test-sid"
    )

    let flat1 = TranscriptLayout.FlattenCache.flatten(
      cache: &flattenCache,
      completed: transcriptLines,
      open: nil,
      width: cols,
      generation: 0)
    let contentRows1 = SlateChatRenderer.transcriptContentRows(
      cols: cols, rows: rows, banner: banner, usage: nil,
      inputLine: "typing...", waitingForLLM: false, queuedTraySnapshot: QueuedTraySnapshot())
    _ = viewport.resolve(flatCount: flat1.count, contentRows: contentRows1)

    let grid1 = SlateChatRenderer.buildGrid(
      cols: cols, rows: rows,
      flattenedTranscript: flat1,
      transcriptTailStart: viewport.firstVisibleRow,
      banner: banner, usage: nil,
      inputLine: "typing...",
      inputMode: .edit,
      llmWaitAnimationFrame: 0,
      waitingForLLM: false,
      queuedTraySnapshot: QueuedTraySnapshot(),
      theme: theme)

    let headerRows = 3
    let rowBelowHeader = headerRows
    #expect(
      grid1[rowBelowHeader][0].text == " ",
      "Frame 1: transcript area should be blank")

    transcriptLines.append(
      TLine(spans: [StyledSpan(fg: theme.userPrefix, bg: theme.background, bold: false, text: "you:")]))
    transcriptLines.append(
      TLine(spans: [StyledSpan(fg: theme.userBody, bg: theme.background, bold: false, text: "  hello")]))

    let flat2 = TranscriptLayout.FlattenCache.flatten(
      cache: &flattenCache,
      completed: transcriptLines,
      open: nil,
      width: cols,
      generation: 0)

    let contentRows2 = SlateChatRenderer.transcriptContentRows(
      cols: cols, rows: rows, banner: banner, usage: nil,
      inputLine: "", waitingForLLM: true, queuedTraySnapshot: QueuedTraySnapshot())
    _ = viewport.resolve(flatCount: flat2.count, contentRows: contentRows2)

    let grid2 = SlateChatRenderer.buildGrid(
      cols: cols, rows: rows,
      flattenedTranscript: flat2,
      transcriptTailStart: viewport.firstVisibleRow,
      banner: banner, usage: nil,
      inputLine: "",
      inputMode: .edit,
      llmWaitAnimationFrame: 0,
      waitingForLLM: true,
      queuedTraySnapshot: QueuedTraySnapshot(),
      theme: theme)

    let expectedFirstContentRow = 3 + (contentRows2 - flat2.count)
    #expect(expectedFirstContentRow == 21)

    let youCell = grid2[expectedFirstContentRow][0]
    #expect(
      youCell.text == "y",
      "Frame 2: Expected 'y' from 'you:' at row \(expectedFirstContentRow), got '\(youCell.text)'")

    let helloCell = grid2[expectedFirstContentRow + 1][2]
    #expect(
      helloCell.text == "h",
      "Frame 2: Expected 'h' from 'hello' at row \(expectedFirstContentRow + 1) col 2, got '\(helloCell.text)'")
  }

  @Test func viewportFollowsLiveThroughFirstMessage() {
    var viewport = TranscriptViewport()

    #expect(viewport.followingLive == true)
    let pos0 = viewport.resolve(flatCount: 0, contentRows: 20)
    #expect(pos0 == 0)
    #expect(viewport.followingLive == true)

    let pos1 = viewport.resolve(flatCount: 2, contentRows: 20)
    #expect(pos1 == 0)
    #expect(
      viewport.followingLive == true,
      "Viewport should still be following live after first message")

    let pos2 = viewport.resolve(flatCount: 100, contentRows: 20)
    #expect(pos2 == 80)
    #expect(viewport.followingLive == true)
  }

  @Test func flattenCacheAppendsNewLines() {
    var cache = TranscriptLayout.FlattenCache()

    let flat0 = TranscriptLayout.FlattenCache.flatten(
      cache: &cache, completed: [], open: nil, width: 80, generation: 0)
    #expect(flat0.isEmpty)

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

  @Test func generationChangeResetsFlattenCache() {
    var cache = TranscriptLayout.FlattenCache()

    let lines1: [TLine] = [
      TLine(spans: [StyledSpan(fg: .blue, bg: .black, bold: false, text: "line1")])
    ]
    _ = TranscriptLayout.FlattenCache.flatten(
      cache: &cache, completed: lines1, open: nil, width: 80, generation: 0)

    let lines2: [TLine] = [
      TLine(spans: [StyledSpan(fg: .blue, bg: .black, bold: false, text: "line1")]),
      TLine(spans: [StyledSpan(fg: .white, bg: .black, bold: false, text: "line2")]),
    ]
    let flat = TranscriptLayout.FlattenCache.flatten(
      cache: &cache, completed: lines2, open: nil, width: 80, generation: 1)

    #expect(flat.count == 2)
    #expect(flat[0].spans.first?.text == "line1")
    #expect(flat[1].spans.first?.text == "line2")
  }
}
