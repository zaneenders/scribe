import Chroma
import ChromaTesting
import Testing

@testable import ScribeBlocks

@MainActor
private final class ShortcutState {
  let focus = FocusTarget()
  var context: BlockContext?
  var text = ""
  var submitted = 0
  var stopped = 0
  var commands: [Command] = []
}

private struct ShortcutSurface: Block {
  let state: ShortcutState

  @MainActor var body: some Block {
    BlockContextBridge(
      content: TextEditor(
        "", fontScale: 1,
        text: { state.text }, onChange: { state.text = $0 },
        onEndEditing: {
          state.stopped += 1
          return .handled
        },
        onTextEvent: { event, text in event == .moveCaretUp && text.isEmpty ? "previous prompt" : nil }
      ).focusTarget(state.focus),
      prepare: {
        state.context = $0
        state.commands += $0.input.commands
      })
  }
}

@MainActor
struct ShortcutTests {
  @Test func portableKeysReachComposerAndPickerCommands() throws {
    let state = ShortcutState()
    let content = ShortcutSurface(state: state)
      .onCommand(ScribeComposerCommand.submit) {
        guard state.focus.isEditing else { return .ignored }
        state.submitted += 1
        return .handled
      }
    let ui = NavigationTestHost(
      content: content, size: Size(width: 400, height: 100), keyBindings: ScribeBlock.keyBindings)
    defer { ui.host.close() }
    let context = try #require(state.context)
    state.focus.focus(editing: true)
    ui.host.render()
    func key(_ key: Key, modifiers: KeyModifiers = [], text: String? = nil) {
      ui.press(KeyboardInput(chord: KeyChord(key, modifiers: modifiers), text: text))
    }
    #if os(macOS)
    let modifier = KeyModifiers.command
    #else
    let modifier = KeyModifiers.superKey
    #endif
    key(.enter, modifiers: modifier)
    #expect(state.submitted == 1)
    #expect(state.text.isEmpty)
    key(.upArrow)
    #expect(state.text.isEmpty)
    for arrow: Key in [.upArrow, .downArrow, .leftArrow, .rightArrow] {
      for isEditing in [false, true] {
        #expect(ScribeBlock.keyBindings.command(for: KeyChord(arrow), isTextEditing: isEditing) == .some(nil))
      }
    }
    key(.escape)
    #expect(state.stopped == 1)
    #expect(state.focus.isEditing)
    key(.enter)
    #expect(state.text == "\n")
    key(.character("f"), text: "f")
    #expect(state.text.contains("f"))
    key(.space, text: " ")
    #expect(state.text == "\nf ")
    context.endEditing()
    key(.character("f"), text: "f")
    key(.character("j"), text: "j")
    key(.tab)
    #expect(state.commands.contains(.navigation(.up)))
    #expect(state.commands.contains(.navigation(.down)))
    #expect(state.commands.contains(.navigation(.nextFocus)))
    for (key, command) in [
      ("d", NavigationCommand.sectionLeft), ("f", .sectionUp),
      ("j", .sectionDown), ("k", .sectionRight),
    ] {
      #expect(
        ScribeBlock.keyBindings.command(for: KeyChord(Character(key), modifiers: .control), isTextEditing: false)
          == .some(.navigation(command)))
      #expect(
        ScribeBlock.keyBindings.command(for: KeyChord(Character(key), modifiers: .control), isTextEditing: true)
          == .some(.navigation(command)))
    }
    #expect(
      ScribeCommandPickerCommand.keyBindings.command(for: KeyChord("f"), isTextEditing: false)
        == .some(ScribeCommandPickerCommand.previous))
    #expect(
      ScribeCommandPickerCommand.keyBindings.command(for: KeyChord("j"), isTextEditing: false)
        == .some(ScribeCommandPickerCommand.next))
    #expect(
      ScribeCommandPickerCommand.keyBindings.command(for: KeyChord(.tab), isTextEditing: false)
        == .some(ScribeCommandPickerCommand.toggle))
    #expect(
      ScribeCommandPickerCommand.keyBindings.command(for: KeyChord(.tab), isTextEditing: true)
        == .some(ScribeCommandPickerCommand.toggle))
    #expect(
      ScribeBlock.keyBindings.command(for: KeyChord(.escape), isTextEditing: false) == .some(.action(.cancel)))
    key(.enter, modifiers: modifier)
    #expect(state.submitted == 1)
    key(.space, text: " ")
    #expect(state.commands.contains(.action(.activate)))
    #expect(state.text == "\nf ")
  }
}
