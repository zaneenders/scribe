import Chroma
import Foundation
import Testing

@testable import ScribeBlocks

@Suite("Mac transcript selection")
struct MacSelectionTests {
  @Test("only an active drag or its release frame updates selection")
  func selectionDragStateTruthTable() {
    #expect(
      shouldProcessSelectionDrag(
        isDragging: false,
        pointerReleased: true,
        hasDragOrigin: true))
    #expect(
      !shouldProcessSelectionDrag(
        isDragging: false,
        pointerReleased: true,
        hasDragOrigin: false))
    #expect(
      shouldProcessSelectionDrag(
        isDragging: true,
        pointerReleased: false,
        hasDragOrigin: true))
    #expect(
      shouldProcessSelectionDrag(
        isDragging: true,
        pointerReleased: false,
        hasDragOrigin: false))
    #expect(
      !shouldProcessSelectionDrag(
        isDragging: false,
        pointerReleased: false,
        hasDragOrigin: true))
    #expect(
      !shouldProcessSelectionDrag(
        isDragging: false,
        pointerReleased: false,
        hasDragOrigin: false))
  }

  @MainActor
  @Test("a focused editor without a selection does not suppress transcript copy")
  func focusedEditorDoesNotSuppressTranscriptCopy() {
    let cleanup = installSelectionFixture(text: "selected transcript")
    defer { cleanup() }

    #expect(SelectionManager.shared.selectAll(isTranscriptVisible: true))
    #expect(
      SelectionManager.shared.copyText(isTranscriptVisible: true)
        == "selected transcript")
  }

  @MainActor
  @Test("a hidden transcript cannot own copy or select all")
  func hiddenTranscriptDoesNotOwnClipboardCommands() {
    let cleanup = installSelectionFixture(text: "hidden transcript")
    defer { cleanup() }

    #expect(SelectionManager.shared.selectAll(isTranscriptVisible: true))
    #expect(SelectionManager.shared.copyText(isTranscriptVisible: false) == nil)
    #expect(!SelectionManager.shared.selectAll(isTranscriptVisible: false))
  }

  @MainActor
  private func installSelectionFixture(text: String) -> @MainActor () -> Void {
    installSelectionFixture(texts: [text]).cleanup
  }

  @MainActor
  private func installSelectionFixture(texts: [String]) -> (
    entries: [TranscriptSelectionDocumentRegistry.Entry], cleanup: @MainActor () -> Void
  ) {
    installSelectionFixture(ownerID: UUID(), texts: texts)
  }

  @MainActor
  private func installSelectionFixture(ownerID: UUID, texts: [String]) -> (
    entries: [TranscriptSelectionDocumentRegistry.Entry], cleanup: @MainActor () -> Void
  ) {
    SelectionManager.shared.clear()
    MarkdownLayoutRegistry.clear()

    var entries: [TranscriptSelectionDocumentRegistry.Entry] = []
    for (index, text) in texts.enumerated() {
      let id = WidgetID("selection-test-\(UUID().uuidString)")
      let layout = makeLayout(
        text: text,
        rect: Rect(x: 10, y: 10 + Float(index) * 20, width: Float(text.count) * 8, height: 12))
      MarkdownLayoutRegistry.register(id, layout: layout)
      let line = layout.lines[0]
      entries.append(
        TranscriptSelectionDocumentRegistry.Entry(
          id: id,
          linesForColumns: { _ in [line] }))
    }
    TranscriptSelectionDocumentRegistry.setEntries(ownerID: ownerID, entries)

    return (
      entries,
      {
        SelectionManager.shared.clear()
        MarkdownLayoutRegistry.clear()
        TranscriptSelectionDocumentRegistry.setEntries(ownerID: UUID(), [])
      }
    )
  }

  private func makeLayout(text: String, rect: Rect) -> MarkdownLayout {
    let line = VisualLine(
      runs: [VisualRun(text: text, color: .white)],
      columnCount: text.count)
    return MarkdownLayout(
      lines: [line], lineHeight: 12, cellWidth: 8, scale: 1, rect: rect)
  }

  @MainActor
  @Test("select all copies every document entry in transcript order")
  func selectAllCopiesTheWholeDocument() {
    let fixture = installSelectionFixture(texts: ["◆ Scribe", "first body", "⌘ shell", "last body"])
    defer { fixture.cleanup() }

    #expect(SelectionManager.shared.selectAll(isTranscriptVisible: true))
    #expect(
      SelectionManager.shared.copyText(isTranscriptVisible: true)
        == "◆ Scribe\nfirst body\n⌘ shell\nlast body")
  }

  @MainActor
  @Test("clearing removes selection and clipboard ownership")
  func clearRemovesSelection() {
    let cleanup = installSelectionFixture(text: "selected transcript")
    defer { cleanup() }

    #expect(SelectionManager.shared.selectAll(isTranscriptVisible: true))
    SelectionManager.shared.clear()
    #expect(SelectionManager.shared.selectedText() == nil)
    #expect(SelectionManager.shared.copyText(isTranscriptVisible: true) == nil)
  }

  @MainActor
  @Test("changing transcript owner invalidates the old selection")
  func changingOwnerClearsSelection() {
    let cleanup = installSelectionFixture(text: "old session")
    defer { cleanup() }

    #expect(SelectionManager.shared.selectAll(isTranscriptVisible: true))
    TranscriptSelectionDocumentRegistry.setEntries(ownerID: UUID(), [])
    #expect(SelectionManager.shared.selectedText() == nil)
  }

  @MainActor
  @Test("removing a selected endpoint invalidates the selection")
  func removingEndpointClearsSelection() {
    let owner = UUID()
    let fixture = installSelectionFixture(ownerID: owner, texts: ["header", "body"])
    defer { fixture.cleanup() }

    #expect(SelectionManager.shared.selectAll(isTranscriptVisible: true))
    TranscriptSelectionDocumentRegistry.setEntries(ownerID: owner, [fixture.entries[0]])
    #expect(SelectionManager.shared.selectedText() == nil)
  }

  @MainActor
  @Test("retaining all selected endpoints preserves selection")
  func retainingEndpointsPreservesSelection() {
    let owner = UUID()
    let fixture = installSelectionFixture(ownerID: owner, texts: ["header", "body"])
    defer { fixture.cleanup() }

    #expect(SelectionManager.shared.selectAll(isTranscriptVisible: true))
    TranscriptSelectionDocumentRegistry.setEntries(ownerID: owner, fixture.entries)
    #expect(SelectionManager.shared.selectedText() == "header\nbody")
  }

  @Test("layout hit testing rounds to the nearest cell and clamps")
  func layoutHitTesting() {
    let layout = makeLayout(text: "abcd", rect: Rect(x: 10, y: 20, width: 40, height: 12))
    #expect(layout.hitTest(point: Point(x: 10, y: 20))?.line == 0)
    #expect(layout.hitTest(point: Point(x: 10, y: 20))?.column == 0)
    #expect(layout.hitTest(point: Point(x: 16, y: 25))?.column == 1)
    #expect(layout.hitTest(point: Point(x: 49, y: 25))?.column == 4)
    #expect(layout.hitTest(point: Point(x: 9, y: 25)) == nil)
    #expect(layout.hitTest(point: Point(x: 20, y: 33)) == nil)
  }

  @Test("invalid layout metrics cannot be hit tested")
  func invalidMetricsCannotBeHitTested() {
    var layout = makeLayout(text: "abcd", rect: Rect(x: 0, y: 0, width: 40, height: 12))
    layout.cellWidth = 0
    #expect(layout.hitTest(point: Point(x: 1, y: 1)) == nil)
    layout.cellWidth = 10
    layout.lineHeight = .infinity
    #expect(layout.hitTest(point: Point(x: 1, y: 1)) == nil)
  }

  @Test("selection glyph offsets survive visual reflow")
  func glyphOffsetsSurviveReflow() {
    let color = Color.white
    let narrow = MarkdownLayout(
      lines: [
        VisualLine(
          runs: [VisualRun(text: "abcd", color: color)], columnCount: 4, trailingText: ""),
        VisualLine(runs: [VisualRun(text: "efgh", color: color)], columnCount: 4),
      ], lineHeight: 10, cellWidth: 5, scale: 1)
    let wide = MarkdownLayout(
      lines: [VisualLine(runs: [VisualRun(text: "abcdefgh", color: color)], columnCount: 8)],
      lineHeight: 10, cellWidth: 5, scale: 1)

    let offset = narrow.glyphOffset(at: (line: 1, column: 2))
    #expect(offset == 6)
    #expect(wide.position(atGlyphOffset: offset) == (line: 0, column: 6))
    #expect(narrow.position(atGlyphOffset: 4) == (line: 1, column: 0))
    #expect(
      narrow.textInRange(
        from: narrow.position(atGlyphOffset: 4),
        to: narrow.position(atGlyphOffset: 8)) == "efgh")
  }

  @Test("glyph positions and offsets clamp outside layout bounds")
  func glyphCoordinatesClamp() {
    let layout = MarkdownLayout(
      lines: [
        VisualLine(runs: [VisualRun(text: "abc", color: .white)], columnCount: 3),
        VisualLine(runs: [VisualRun(text: "de", color: .white)], columnCount: 2),
      ], lineHeight: 10, cellWidth: 5, scale: 1)

    #expect(layout.glyphOffset(at: (line: -10, column: -10)) == 0)
    #expect(layout.glyphOffset(at: (line: 99, column: 99)) == 6)
    #expect(layout.position(atGlyphOffset: -10) == (line: 0, column: 0))
    #expect(layout.position(atGlyphOffset: 99) == (line: 1, column: 2))
  }

  @Test("text extraction spans runs and preserves logical separators")
  func textExtractionAcrossRunsAndLines() {
    let layout = MarkdownLayout(
      lines: [
        VisualLine(
          runs: [
            VisualRun(text: "ab", color: .white),
            VisualRun(text: "cd", color: .black),
          ], columnCount: 4, trailingText: " "),
        VisualLine(runs: [VisualRun(text: "efgh", color: .white)], columnCount: 4),
      ], lineHeight: 10, cellWidth: 5, scale: 1)

    #expect(layout.textInRange(from: (line: 0, column: 1), to: (line: 1, column: 3)) == "bcd efg")
  }

  @Test("text extraction clamps ranges and rejects reversed ranges")
  func textExtractionClampsAndRejectsReversedRanges() {
    let layout = makeLayout(text: "abcd", rect: .zero)
    #expect(layout.textInRange(from: (line: -2, column: -4), to: (line: 8, column: 40)) == "abcd")
    #expect(layout.textInRange(from: (line: 0, column: 3), to: (line: 0, column: 2)).isEmpty)
    #expect(layout.textInRange(from: (line: 0, column: 2), to: (line: 0, column: 2)).isEmpty)
  }

  @Test("empty layouts have safe coordinate and extraction behavior")
  func emptyLayoutBehavior() {
    let layout = MarkdownLayout(lines: [], lineHeight: 10, cellWidth: 5, scale: 1)
    #expect(layout.glyphCount == 0)
    #expect(layout.glyphOffset(at: (line: 4, column: 4)) == 0)
    #expect(layout.position(atGlyphOffset: 4) == (line: 0, column: 0))
    #expect(layout.textInRange(from: (line: 0, column: 0), to: (line: 0, column: 4)).isEmpty)
  }

  @Test("reflow preserves spaces consumed at wrap boundaries")
  func spacesSurviveReflow() {
    let theme = MacTheme()
    let blocks = segmentMarkdown("abcdefgh x")
    let narrow = MarkdownLayout(
      lines: layoutMarkdown(blocks, columns: 8, theme: theme, baseColor: .white),
      lineHeight: 10, cellWidth: 5, scale: 1)
    let wide = MarkdownLayout(
      lines: layoutMarkdown(blocks, columns: 20, theme: theme, baseColor: .white),
      lineHeight: 10, cellWidth: 5, scale: 1)

    let xOffset = wide.glyphOffset(at: (line: 0, column: 9))
    #expect(xOffset == 9)
    #expect(narrow.position(atGlyphOffset: xOffset) == (line: 1, column: 0))
    #expect(
      narrow.textInRange(
        from: (line: 0, column: 0),
        to: (line: 1, column: 1)) == "abcdefgh x")
  }

  @Test("selection outside the viewport requests autoscroll")
  func selectionAutoscroll() {
    let viewport = Rect(x: 0, y: 100, width: 500, height: 300)
    #expect(selectionAutoscrollTarget(pointer: Point(x: 20, y: 50), viewport: viewport)?.minY == 82)
    #expect(selectionAutoscrollTarget(pointer: Point(x: 20, y: 450), viewport: viewport)?.minY == 418)
    #expect(selectionAutoscrollTarget(pointer: Point(x: 20, y: 200), viewport: viewport) == nil)
  }

  @Test("autoscroll respects viewport boundaries and custom step")
  func autoscrollBoundariesAndStep() {
    let viewport = Rect(x: 0, y: 100, width: 500, height: 300)
    #expect(selectionAutoscrollTarget(pointer: Point(x: 20, y: 100), viewport: viewport) == nil)
    #expect(selectionAutoscrollTarget(pointer: Point(x: 20, y: 400), viewport: viewport) == nil)
    #expect(
      selectionAutoscrollTarget(pointer: Point(x: 20, y: 99), viewport: viewport, step: 7)?.minY
        == 93)
    #expect(
      selectionAutoscrollTarget(pointer: Point(x: 20, y: 401), viewport: viewport, step: 7)?.minY
        == 407)
    #expect(selectionAutoscrollTarget(pointer: Point(x: 20, y: 50), viewport: viewport, step: 0) == nil)
    #expect(
      selectionAutoscrollTarget(pointer: Point(x: 20, y: 50), viewport: viewport, step: .infinity)
        == nil)
  }
}
