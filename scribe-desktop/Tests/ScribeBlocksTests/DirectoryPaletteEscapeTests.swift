import Chroma
import ChromaTesting
import Testing

@testable import ScribeBlocks

@MainActor
private final class PaletteEscapeState {
  var context: BlockContext?
  var underlyingPickerCancelled = false
}

private struct PaletteEscapeSurface: Block {
  let store: ScribeMacStore
  let state: PaletteEscapeState

  @MainActor var body: some Block {
    BlockContextBridge(
      content: PaletteEscapeContent(store: store),
      prepare: { state.context = $0 },
      finish: { context in
        if !store.showDirectoryPicker, store.renamingSessionID == nil,
          context.input.textEvents.contains(.endEditing)
        {
          state.underlyingPickerCancelled = true
        }
        store.finishDirectoryPaletteInput(context)
      })
  }
}

private struct PaletteEscapeContent: Block {
  let store: ScribeMacStore

  @MainActor @BlockBuilder var body: some Block {
    if store.showDirectoryPicker {
      DirectoryPalette(store: store, theme: MacTheme(), required: store.requiresDirectoryBeforeStart)
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
    let renderer = HeadlessHost(size: Size(width: 640, height: 400))
    defer { renderer.close() }
    renderer.content = PaletteEscapeSurface(store: store, state: state)
    renderer.render()
    _ = try #require(state.context)
    ScribeMacStore.directoryPaletteFocus.focus(editing: true)
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
