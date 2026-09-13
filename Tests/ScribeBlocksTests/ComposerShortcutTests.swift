import Chroma
import Testing

@testable import ScribeBlocks

struct ComposerShortcutTests {
  @MainActor
  @Test func commandEnterIsTransportableAndScopedToComposer() {
    #if os(macOS)
    let modifier = KeyModifiers.command
    #else
    let modifier = KeyModifiers.superKey
    #endif
    let bindings = ScribeBlock.keyBindings
    #expect(bindings.command(for: KeyChord(.enter, modifiers: modifier)) == .some(.some(ScribeComposerCommand.submit)))
    #expect(ScribeComposerCommand.shouldSubmit(ScribeComposerCommand.submit, activeTextInput: ScribeMacStore.composerID))
    #expect(!ScribeComposerCommand.shouldSubmit(ScribeComposerCommand.submit, activeTextInput: nil))
    #expect(!ScribeComposerCommand.shouldSubmit(ScribeComposerCommand.submit, activeTextInput: WidgetID("directory")))
    #expect(bindings.command(for: KeyChord(.enter)) == .some(.some(.editing(.submit))))
    #expect(bindings.command(for: KeyChord(.enter, modifiers: .shift)) == .some(.some(.editing(.submit))))
  }
}
