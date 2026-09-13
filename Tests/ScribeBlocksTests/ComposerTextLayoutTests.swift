import Testing
import Chroma
import HeadlessBackend

@testable import ScribeBlocks

@MainActor
struct ComposerTextLayoutTests {
  @Test func repeatedFramesOnlyEmitVisibleTextAndReuseLayout() {
    var text = String(repeating: "log payload\n", count: 800)
    var revision: UInt64 = 1
    let cache = ComposerTextLayoutCache()
    let renderer = HeadlessRenderer(size: Size(width: 500, height: 140))
    renderer.content = GrowingTextField(
      "", id: WidgetID("large-draft"), fontScale: 1,
      text: { text }, layoutCache: cache, revision: { revision },
      onChange: { text = $0; revision &+= 1 }, onNewline: {})
    defer { renderer.close() }
    for _ in 0..<20 {
      let frame = renderer.render()
      let strings = frame.commands.compactMap { command -> String? in
        if case .text(_, let text, _, _) = command { return text }
        return nil
      }
      #expect(strings.count <= 6)
      #expect(strings.joined().count < 100)
    }
    #expect(cache.buildCount == 1)
    text += "new"
    revision += 1
    _ = renderer.render()
    #expect(cache.buildCount == 2)
    renderer.viewport = Size(width: 300, height: 140)
    _ = renderer.render()
    #expect(cache.buildCount == 3)
  }

  @Test func wrappingPreservesExistingBoundaryAndNewlineSemantics() {
    let layout = ComposerTextLayout(text: "abcd\nx\n", columns: 4)
    #expect(layout.rows.map { layout.text(for: $0) } == ["abcd", "", "x", ""])
    #expect(layout.rows.map(\.start) == [0, 4, 5, 7])
    #expect(layout.rowIndex(containing: 4) == 1)
    #expect(layout.rowIndex(containing: 5) == 2)
    #expect(layout.rowIndex(containing: nil) == 3)
    #expect(ComposerTextLayout(text: "", columns: 4).rows.count == 1)
    #expect(ComposerTextLayout(text: "abcd", columns: 4).rows.count == 1)
  }

  @Test func characterOffsetsPreserveUnicode() {
    let layout = ComposerTextLayout(text: "👨‍👩‍👧‍👦e\u{301}🙂\nx", columns: 2)
    #expect(layout.rows.map { layout.text(for: $0) } == ["👨‍👩‍👧‍👦e\u{301}", "🙂", "x"])
    #expect(layout.rows.map(\.start) == [0, 2, 4])
    #expect(layout.rows.map(\.count) == [2, 1, 1])
  }

  @Test func largeUnchangedDraftBuildsOnceAndMeasurementIsBounded() {
    let text = String(repeating: "log line with payload\n", count: 8_000)
    let cache = ComposerTextLayoutCache()
    #expect(cache.lineCount(text: text, revision: 1, columns: 80, limit: 6) == 6)
    #expect(cache.buildCount == 0)
    let bounded = ComposerTextLayout(text: text, columns: 80, limit: 6)
    #expect(bounded.rows.count == 6)
    #expect(bounded.rows.last!.end < 200)
    let layout = cache.layout(text: text, revision: 1, columns: 80)
    #expect(layout.rows.count == 8_001)
    for _ in 0..<100 {
      #expect(cache.lineCount(text: text, revision: 1, columns: 80, limit: 6) == 6)
      #expect(cache.layout(text: text, revision: 1, columns: 80).rowIndex(containing: text.count) == 8_000)
    }
    #expect(cache.buildCount == 1)
    _ = cache.layout(text: text + "new", revision: 2, columns: 80)
    #expect(cache.buildCount == 2)
    _ = cache.layout(text: text + "new", revision: 2, columns: 40)
    #expect(cache.buildCount == 3)
  }

  @Test func unversionedCallersInvalidateByContent() {
    let cache = ComposerTextLayoutCache()
    _ = cache.layout(text: "old", revision: nil, columns: 20)
    let updated = cache.layout(text: "new", revision: nil, columns: 20)
    #expect(updated.text == "new")
    #expect(cache.buildCount == 2)
  }
}
