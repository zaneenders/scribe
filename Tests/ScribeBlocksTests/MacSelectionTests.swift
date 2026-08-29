import Chroma
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
  @Test("an active editor prevents transcript copy fallback")
  func editorOwnsCopy() {
    #expect(SelectionManager.shared.copyText(interactionMode: .editing) == nil)
  }
}
