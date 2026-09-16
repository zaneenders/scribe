import Chroma
import Testing

@testable import ScribeBlocks

struct ComposerShortcutTests {
  @Test func clipboardShortcutsUsePlatformModifiers() {
    #if os(macOS)
    let modifiers: [KeyModifiers] = [.command, .control]
    #elseif os(Linux)
    let modifiers: [KeyModifiers] = [.control, .superKey]
    #else
    let modifiers: [KeyModifiers] = [.control]
    #endif
    let bindings = ScribeBlock.keyBindings
    let shortcuts: [(Character, TextEditEvent)] = [
      ("c", .copy), ("x", .cut), ("v", .paste), ("a", .selectAll),
    ]
    for modifier in modifiers {
      for (key, event) in shortcuts {
        let chord = KeyChord(.character(key), modifiers: modifier)
        #expect(bindings.command(for: chord) == .some(.some(.editing(event))))
        #expect(!bindings.prefersTextInsertion(chord: chord, text: String(key), isTextEditing: true))
      }
    }
  }

  @MainActor
  @Test func commandEnterIsTransportableAndScopedToComposer() {
    #if os(macOS)
    let modifier = KeyModifiers.command
    #else
    let modifier = KeyModifiers.superKey
    #endif
    let bindings = ScribeBlock.keyBindings
    #expect(bindings.command(for: KeyChord(.enter, modifiers: modifier)) == .some(.some(ScribeComposerCommand.submit)))
    #expect(
      ScribeComposerCommand.shouldSubmit(ScribeComposerCommand.submit, activeTextInput: ScribeMacStore.composerID))
    #expect(!ScribeComposerCommand.shouldSubmit(ScribeComposerCommand.submit, activeTextInput: nil))
    #expect(!ScribeComposerCommand.shouldSubmit(ScribeComposerCommand.submit, activeTextInput: WidgetID("directory")))
    #expect(bindings.command(for: KeyChord(.enter)) == .some(.some(.editing(.submit))))
    #expect(bindings.command(for: KeyChord(.enter, modifiers: .shift)) == .some(.some(.editing(.submit))))
  }
}
