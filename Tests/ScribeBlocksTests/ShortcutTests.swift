import Chroma
import HeadlessBackend
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

private struct ShortcutSurface: PrimitiveBlock {
  var focusRule: FocusRule { .container }
  let state: ShortcutState
  @MainActor func sizeThatFits(_ proposal: Size, context: BlockContext) -> Size { proposal }
  @MainActor func draw(into list: inout DrawList, in rect: Rect, context: BlockContext) {
    state.context = context
    state.commands += context.input.commands
    let field = TextEditor(
      "", fontScale: 1,
      text: { state.text }, onChange: { state.text = $0 },
      onEndEditing: {
        state.stopped += 1
        return .handled
      },
      onTextEvent: { event, text in event == .moveCaretUp && text.isEmpty ? "previous prompt" : nil })
    BlockEngine.draw(field.focusTarget(state.focus), into: &list, in: rect, context: context)
  }
}

@MainActor
struct ShortcutTests {
  @Test func portableKeysReachComposerAndPickerCommands() throws {
    let state = ShortcutState()
    let renderer = HeadlessHost(size: Size(width: 400, height: 100))
    renderer.content = ShortcutSurface(state: state)
      .onCommand(ScribeComposerCommand.submit) {
        guard state.focus.isEditing else { return .ignored }
        state.submitted += 1
        return .handled
      }
    renderer.render()
    let context = try #require(state.context)
    state.focus.focus(editing: true)
    renderer.render()
    func key(_ key: Key, modifiers: KeyModifiers = [], text: String? = nil) {
      let chord = KeyChord(key, modifiers: modifiers)
      let bindings = ScribeBlock.keyBindings
      var input = InputState()
      switch bindings.resolve(KeyboardInput(chord: chord, text: text), isTextEditing: context.interactionMode == .editing) {
      case .text(let event): input.textEvents.append(event)
      case .command(let command): input.commands.append(command)
      case nil: break
      }
      renderer.render(input: input)
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
    #expect(state.text == "previous prompt")
    key(.escape)
    #expect(state.stopped == 1)
    #expect(state.focus.isEditing)
    key(.enter)
    #expect(state.text == "previous prompt\n")
    key(.character("f"), text: "f")
    #expect(state.text.contains("f"))
    key(.space, text: " ")
    #expect(state.text == "previous prompt\nf ")
    context.endEditing()
    key(.character("f"), text: "f")
    key(.character("j"), text: "j")
    key(.tab)
    #expect(state.commands.contains(ScribeCommandPickerCommand.previous))
    #expect(state.commands.contains(ScribeCommandPickerCommand.next))
    #expect(state.commands.contains(ScribeCommandPickerCommand.toggle))
    key(.enter, modifiers: modifier)
    #expect(state.submitted == 1)
    key(.space, text: " ")
    #expect(state.commands.contains(.action(.activate)))
    #expect(state.text == "previous prompt\nf ")
  }
}
