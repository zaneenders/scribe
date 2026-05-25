import Foundation
import Testing

@testable import ScribeCLI

@Suite
@MainActor
struct RenderLoopTests {

  @Test func emptyTranscript() {
    var state = RenderState(
      transcriptLines: [],
      streamingOpenLine: nil,
      generation: 0,
      flattenCache: TranscriptLayout.FlattenCache(),
      banner: nil,
      usageHUD: nil,
      inputBuffer: "",
      modelBusy: false,
      queuedTraySnapshot: QueuedTraySnapshot(),
      llmWaitAnimationFrame: 0,
      viewport: TranscriptViewport(),
      cols: 80,
      rows: 24
    )
    let output = RenderLoop.buildFrame(state: &state)
    #expect(output.flattenedTranscript.isEmpty)
    #expect(output.transcriptTailStart == 0)
  }

  @Test func smallTranscriptFitsOnScreen() {
    let lines = [
      TLine(spans: [StyledSpan(fg: .blue, bg: .black, bold: false, text: "you:")]),
      TLine(spans: [StyledSpan(fg: .white, bg: .black, bold: false, text: "  hello")]),
    ]
    var state = RenderState(
      transcriptLines: lines,
      streamingOpenLine: nil,
      generation: 0,
      flattenCache: TranscriptLayout.FlattenCache(),
      banner: BannerSnapshot(baseURL: "", model: "", cwd: "", scribeVersion: "", gitBranch: nil, sessionId: ""),
      usageHUD: nil,
      inputBuffer: "",
      modelBusy: true,
      queuedTraySnapshot: QueuedTraySnapshot(),
      llmWaitAnimationFrame: 0,
      viewport: TranscriptViewport(),
      cols: 80,
      rows: 24
    )
    let output = RenderLoop.buildFrame(state: &state)

    #expect(output.flattenedTranscript.count == 2)
    #expect(output.transcriptTailStart == 0)
  }

  @Test func largeTranscriptTracksTail() {
    var lines: [TLine] = []
    for i in 0..<100 {
      lines.append(TLine(spans: [StyledSpan(fg: .white, bg: .black, bold: false, text: "line \(i)")]))
    }
    var state = RenderState(
      transcriptLines: lines,
      streamingOpenLine: nil,
      generation: 0,
      flattenCache: TranscriptLayout.FlattenCache(),
      banner: BannerSnapshot(baseURL: "", model: "", cwd: "", scribeVersion: "", gitBranch: nil, sessionId: ""),
      usageHUD: nil,
      inputBuffer: "",
      modelBusy: true,
      queuedTraySnapshot: QueuedTraySnapshot(),
      llmWaitAnimationFrame: 0,
      viewport: TranscriptViewport(),
      cols: 80,
      rows: 24
    )
    let output = RenderLoop.buildFrame(state: &state)

    let contentRows = 20
    let expectedTail = max(0, output.flattenedTranscript.count - contentRows)
    #expect(output.transcriptTailStart == expectedTail)
  }

  @Test func viewportScrollUpDisablesFollow() {
    let lines = (0..<50).map {
      TLine(spans: [StyledSpan(fg: .white, bg: .black, bold: false, text: "line \($0)")])
    }
    var viewport = TranscriptViewport()
    viewport.queueScroll(by: -5)

    var state = RenderState(
      transcriptLines: lines,
      streamingOpenLine: nil,
      generation: 0,
      flattenCache: TranscriptLayout.FlattenCache(),
      banner: nil,
      usageHUD: nil,
      inputBuffer: "",
      modelBusy: false,
      queuedTraySnapshot: QueuedTraySnapshot(),
      llmWaitAnimationFrame: 0,
      viewport: viewport,
      cols: 80,
      rows: 24
    )
    let output = RenderLoop.buildFrame(state: &state)

    #expect(!output.viewport.followingLive)
  }

  @Test func flattenCacheReusesOnSameGeneration() {
    let lines = [
      TLine(spans: [StyledSpan(fg: .white, bg: .black, bold: false, text: "test")])
    ]
    let cache = TranscriptLayout.FlattenCache()

    var state1 = RenderState(
      transcriptLines: lines, streamingOpenLine: nil, generation: 1,
      flattenCache: cache, banner: nil, usageHUD: nil, inputBuffer: "",
      modelBusy: false, queuedTraySnapshot: QueuedTraySnapshot(), llmWaitAnimationFrame: 0,
      viewport: TranscriptViewport(), cols: 80, rows: 24
    )
    let output1 = RenderLoop.buildFrame(state: &state1)

    var state2 = RenderState(
      transcriptLines: lines, streamingOpenLine: nil, generation: 1,
      flattenCache: output1.flattenCache, banner: nil, usageHUD: nil, inputBuffer: "",
      modelBusy: false, queuedTraySnapshot: QueuedTraySnapshot(), llmWaitAnimationFrame: 0,
      viewport: TranscriptViewport(), cols: 80, rows: 24
    )
    let output2 = RenderLoop.buildFrame(state: &state2)

    #expect(output2.flattenCache.completedLogicalLines > 0)
  }

  @Test func generationChangeInvalidatesFlattenCache() {
    let lines = [
      TLine(spans: [StyledSpan(fg: .white, bg: .black, bold: false, text: "old")])
    ]
    var cache = TranscriptLayout.FlattenCache()
    cache.completedLogicalLines = 5

    var state = RenderState(
      transcriptLines: lines, streamingOpenLine: nil, generation: 2,
      flattenCache: cache, banner: nil, usageHUD: nil, inputBuffer: "",
      modelBusy: false, queuedTraySnapshot: QueuedTraySnapshot(), llmWaitAnimationFrame: 0,
      viewport: TranscriptViewport(), cols: 80, rows: 24
    )
    let output = RenderLoop.buildFrame(state: &state)

    #expect(output.flattenCache.completedLogicalLines == 1)
  }
}
