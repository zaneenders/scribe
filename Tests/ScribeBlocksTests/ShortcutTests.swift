import Chroma
import HeadlessBackend
import Testing
@testable import ScribeBlocks

@MainActor
private final class ShortcutState {
  var context: RenderContext?
  var text = ""
  var submitted = 0
  var stopped = 0
  var commands: [Command] = []
}

private struct ShortcutSurface: PrimitiveBlock {
  let state: ShortcutState
  @MainActor func sizeThatFits(_ proposal: Size, context: RenderContext) -> Size { proposal }
  @MainActor func draw(into list: inout DrawList, in rect: Rect, context: RenderContext) {
    state.context = context
    state.commands += context.input.commands
    for command in context.input.commands {
      if ScribeComposerCommand.shouldSubmit(command, activeTextInput: context.activeTextInput) {
        state.submitted += 1
      }
    }
    let field = GrowingTextField("", id: ScribeMacStore.composerID, fontScale: 1,
      text: { state.text }, onChange: { state.text = $0 }, onNewline: { state.text += "\n" },
      onEndEditing: { state.stopped += 1; return .handled },
      onTextEvent: { event, text in event == .moveCaretUp && text.isEmpty ? "previous prompt" : nil })
    field.draw(into: &list, in: rect, context: context)
  }
}

@MainActor
struct ShortcutTests {
  @Test func portableKeysReachComposerAndPickerCommands() throws {
    let state = ShortcutState()
    let renderer = HeadlessRenderer(size: Size(width: 400, height: 100))
    renderer.content = ShortcutSurface(state: state)
    renderer.render()
    let context = try #require(state.context)
    context.focus(ScribeMacStore.composerID, editing: true)
    func key(_ key: Key, modifiers: KeyModifiers = [], text: String? = nil) {
      let chord = KeyChord(key, modifiers: modifiers)
      let bindings = ScribeBlock.keyBindings
      var input = InputState()
      if bindings.prefersTextInsertion(chord: chord, text: text, isTextEditing: context.activeTextInput != nil) {
        if let text { input.textEvents.append(.insert(text)) }
      } else if let resolution = bindings.command(for: chord), let command = resolution {
        if case .editing(let event) = command {
          input.textEvents.append(event)
        } else {
          input.commands.append(command)
        }
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
    #expect(context.activeTextInput == ScribeMacStore.composerID)
    key(.enter)
    #expect(state.text == "previous prompt\n")
    key(.character("f"), text: "f")
    #expect(state.text.contains("f")) // printable picker keys still type in composer
    context.endEditing()
    key(.character("f"), text: "f")
    key(.character("j"), text: "j")
    key(.tab)
    #expect(state.commands.contains(ScribeCommandPickerCommand.previous))
    #expect(state.commands.contains(ScribeCommandPickerCommand.next))
    #expect(state.commands.contains(ScribeCommandPickerCommand.toggle))
    key(.enter, modifiers: modifier)
    #expect(state.submitted == 1) // sending is inert outside composer editing
  }
}
