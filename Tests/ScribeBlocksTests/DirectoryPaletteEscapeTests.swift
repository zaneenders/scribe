import Chroma
import ChromaTesting
import Testing

@testable import ScribeBlocks

@MainActor
private final class PaletteEscapeState {
  var context: BlockContext?
  var underlyingPickerCancelled = false
}

private struct PaletteEscapeSurface: PrimitiveBlock {
  var focusRule: FocusRule { .standard }
  let store: ScribeMacStore
  let state: PaletteEscapeState

  @MainActor func sizeThatFits(_ proposal: Size, context: BlockContext) -> Size { proposal }

  @MainActor func draw(into list: inout DrawList, in rect: Rect, context: BlockContext) {
    let bridge = RenderContextBridge(
      content: PaletteEscapeContent(store: store, state: state),
      prepare: { state.context = $0 },
      finish: { store.finishDirectoryPaletteInput($0) })
    bridge.draw(into: &list, in: rect, context: context)
  }
}

private struct PaletteEscapeContent: PrimitiveBlock {
  var focusRule: FocusRule { .standard }
  let store: ScribeMacStore
  let state: PaletteEscapeState

  @MainActor func sizeThatFits(_ proposal: Size, context: BlockContext) -> Size { proposal }

  @MainActor func draw(into list: inout DrawList, in rect: Rect, context: BlockContext) {
    if store.showDirectoryPicker {
      BlockEngine.draw(
        DirectoryPalette(store: store, theme: MacTheme(), required: store.requiresDirectoryBeforeStart),
        into: &list, in: rect, context: context)
    }
    if !store.showDirectoryPicker, store.renamingSessionID == nil,
      context.input.textEvents.contains(.endEditing)
    {
      state.underlyingPickerCancelled = true
    }
  }
}

@MainActor
@Suite(.serialized)
struct DirectoryPaletteEscapeTests {
  @Test(arguments: [false, true])
  func escapeStaysWithinDirectoryPalette(required: Bool) throws {
    let store = ScribeMacStore(startProfiling: false)
    store.showDirectoryPicker = true
    store.requiresDirectoryBeforeStart = required
    let state = PaletteEscapeState()
    let renderer = HeadlessHost(size: Size(width: 640, height: 400))
    defer { renderer.close() }
    renderer.content = PaletteEscapeSurface(store: store, state: state)
    renderer.render()
    _ = try #require(state.context)
    store.directoryPaletteFocus.focus(editing: true)
    renderer.render()
    renderer.render(input: InputState(textEvents: [.endEditing]))
    #expect(store.showDirectoryPicker == required)
    #expect(!state.underlyingPickerCancelled)
    if required {
      let before = store.directoryDraft
      renderer.render(input: InputState(textEvents: [.insert("x")]))
      #expect(store.directoryDraft == before + "x")
    }
  }
}
