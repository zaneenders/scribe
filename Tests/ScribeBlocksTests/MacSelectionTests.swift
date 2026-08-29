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
}
