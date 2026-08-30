import Chroma
import Foundation
import Testing

@testable import ScribeBlocks

@Suite("Mac transcript selection")
struct MacSelectionTests {
  @Test("release frame is included in a drag selection")
  func releaseFrameIsProcessed() {
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
    SelectionManager.shared.clear()
    MarkdownLayoutRegistry.clear()

    let id = WidgetID("selection-test-\(UUID().uuidString)")
    let line = VisualLine(
      runs: [VisualRun(text: text, color: .white)],
      columnCount: text.count)
    let layout = MarkdownLayout(
      lines: [line], lineHeight: 12, cellWidth: 8, scale: 1,
      rect: Rect(x: 10, y: 10, width: Float(text.count) * 8, height: 12))
    MarkdownLayoutRegistry.register(id, layout: layout)
    TranscriptSelectionDocumentRegistry.setEntries(
      ownerID: UUID(),
      [
        TranscriptSelectionDocumentRegistry.Entry(
          id: id,
          linesForColumns: { _ in [line] })
      ])

    return {
      SelectionManager.shared.clear()
      MarkdownLayoutRegistry.clear()
      TranscriptSelectionDocumentRegistry.setEntries(ownerID: UUID(), [])
    }
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
}
