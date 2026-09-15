import Chroma
import HeadlessBackend
import Testing

@testable import ScribeBlocks

@MainActor
private final class PaletteEscapeState {
  var context: RenderContext?
  var underlyingPickerCancelled = false
}

private struct PaletteEscapeSurface: PrimitiveBlock {
  let store: ScribeMacStore
  let state: PaletteEscapeState

  @MainActor func sizeThatFits(_ proposal: Size, context: RenderContext) -> Size { proposal }

  @MainActor func draw(into list: inout DrawList, in rect: Rect, context: RenderContext) {
    let bridge = RenderContextBridge(
      content: PaletteEscapeContent(store: store, state: state),
      prepare: { state.context = $0 },
      finish: { store.finishDirectoryPaletteInput($0) })
    bridge.draw(into: &list, in: rect, context: context)
  }
}

private struct PaletteEscapeContent: PrimitiveBlock {
  let store: ScribeMacStore
  let state: PaletteEscapeState

  @MainActor func sizeThatFits(_ proposal: Size, context: RenderContext) -> Size { proposal }

  @MainActor func draw(into list: inout DrawList, in rect: Rect, context: RenderContext) {
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
    let store = ScribeMacStore.shared
    let oldVisible = store.showDirectoryPicker
    let oldRequired = store.requiresDirectoryBeforeStart
    let oldDraft = store.directoryDraft
    let oldError = store.directoryError
    let oldMatches = store.directoryMatches
    defer {
      store.showDirectoryPicker = oldVisible
      store.requiresDirectoryBeforeStart = oldRequired
      store.directoryDraft = oldDraft
      store.directoryError = oldError
      store.directoryMatches = oldMatches
    }
    store.showDirectoryPicker = true
    store.requiresDirectoryBeforeStart = required
    let state = PaletteEscapeState()
    let renderer = HeadlessRenderer(size: Size(width: 640, height: 400))
    renderer.content = PaletteEscapeSurface(store: store, state: state)
    renderer.render()
    let context = try #require(state.context)
    context.focus(ScribeMacStore.directoryPaletteID, editing: true)
    renderer.render(input: InputState(textEvents: [.endEditing]))
    #expect(store.showDirectoryPicker == required)
    #expect(!state.underlyingPickerCancelled)
    if required {
      #expect(context.activeTextInput == ScribeMacStore.directoryPaletteID)
      let before = store.directoryDraft
      renderer.render(input: InputState(textEvents: [.insert("x")]))
      #expect(store.directoryDraft == before + "x")
    }
  }
}
