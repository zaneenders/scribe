import Foundation
import Testing

@testable import ScribeCLI

@Suite
@MainActor
struct FlattenAndViewportTests {

  @Test func emptyTranscriptFlattensToZero() {
    var cache = TranscriptLayout.FlattenCache()
    let flat = TranscriptLayout.FlattenCache.flatten(
      cache: &cache, completed: [], open: nil, width: 80, generation: 0)
    #expect(flat.isEmpty)

    var viewport = TranscriptViewport()
    _ = viewport.resolve(flatCount: flat.count, contentRows: 24)
    #expect(viewport.firstVisibleRow == 0)
  }

  @Test func smallTranscriptHasTailZero() {
    let lines = [
      TLine(spans: [StyledSpan(fg: .blue, bg: .black, bold: false, text: "you:")]),
      TLine(spans: [StyledSpan(fg: .white, bg: .black, bold: false, text: "  hello")]),
    ]
    var cache = TranscriptLayout.FlattenCache()
    let flat = TranscriptLayout.FlattenCache.flatten(
      cache: &cache, completed: lines, open: nil, width: 80, generation: 0)
    #expect(flat.count == 2)

    var viewport = TranscriptViewport()
    _ = viewport.resolve(flatCount: flat.count, contentRows: 24)
    #expect(viewport.firstVisibleRow == 0)
  }

  @Test func largeTranscriptTailFollowsBottom() {
    let lines = (0..<100).map {
      TLine(spans: [StyledSpan(fg: .white, bg: .black, bold: false, text: "line \($0)")])
    }
    var cache = TranscriptLayout.FlattenCache()
    let flat = TranscriptLayout.FlattenCache.flatten(
      cache: &cache, completed: lines, open: nil, width: 80, generation: 0)

    var viewport = TranscriptViewport()
    let contentRows = 20
    _ = viewport.resolve(flatCount: flat.count, contentRows: contentRows)
    #expect(viewport.firstVisibleRow == max(0, flat.count - contentRows))
  }

  @Test func scrollUpDisablesFollow() {
    var viewport = TranscriptViewport()
    viewport.queueScroll(by: -5)
    _ = viewport.resolve(flatCount: 50, contentRows: 24)
    #expect(!viewport.followingLive)
  }

  @Test func cacheReusesOnSameGeneration() {
    let lines = [
      TLine(spans: [StyledSpan(fg: .white, bg: .black, bold: false, text: "test")])
    ]
    var cache = TranscriptLayout.FlattenCache()
    _ = TranscriptLayout.FlattenCache.flatten(
      cache: &cache, completed: lines, open: nil, width: 80, generation: 1)
    _ = TranscriptLayout.FlattenCache.flatten(
      cache: &cache, completed: lines, open: nil, width: 80, generation: 1)
    #expect(cache.completedLogicalLines > 0)
  }

  @Test func generationChangeInvalidatesCache() {
    var cache = TranscriptLayout.FlattenCache()
    cache.completedLogicalLines = 5
    let lines = [
      TLine(spans: [StyledSpan(fg: .white, bg: .black, bold: false, text: "old")])
    ]
    _ = TranscriptLayout.FlattenCache.flatten(
      cache: &cache, completed: lines, open: nil, width: 80, generation: 2)
    #expect(cache.completedLogicalLines == 1)
  }
}
