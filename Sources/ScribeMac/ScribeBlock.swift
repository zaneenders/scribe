import Chroma

public struct ScribeBlock: Block {
  public init() {}

  @MainActor public var body: some Block {
    let store = ScribeMacStore.shared
    store.start()
    return ScribeMacRoot(store: store)
  }
}

enum ScribeComposerCommand {
  static let submit: Command = .application("scribe.composer.submit")

  @MainActor static func shouldSubmit(_ command: Command, activeTextInput: String?) -> Bool {
    command == submit && activeTextInput == ScribeMacStore.composerID
  }
}

enum ScribeCommandPickerCommand {
  static let previous: Command = .application("scribe.command-picker.previous")
  static let toggle: Command = .application("scribe.command-picker.toggle")
  static let next: Command = .application("scribe.command-picker.next")
}

extension ScribeBlock {
  public static var keyBindings: KeyBindings {
    #if os(macOS)
    let shortcutModifier = KeyModifiers.command
    #elseif os(Linux)
    let shortcutModifier = KeyModifiers.superKey
    #else
    let shortcutModifier = KeyModifiers.control
    #endif

    return KeyBindings {
      bind("c", modifiers: shortcutModifier, to: .editing(.copy))
      bind("x", modifiers: shortcutModifier, to: .editing(.cut))
      bind("v", modifiers: shortcutModifier, to: .editing(.paste))
      bind("a", modifiers: shortcutModifier, to: .editing(.selectAll))
      #if os(macOS) || os(Linux)
      bind("c", modifiers: .control, to: .editing(.copy))
      bind("x", modifiers: .control, to: .editing(.cut))
      bind("v", modifiers: .control, to: .editing(.paste))
      bind("a", modifiers: .control, to: .editing(.selectAll))
      #endif
      bind(.backspace, to: .editing(.backspace))
      bind(.delete, to: .editing(.deleteForward))
      bind(.leftArrow, to: .editing(.moveCaretLeft))
      bind(.rightArrow, to: .editing(.moveCaretRight))
      bind(.upArrow, to: .editing(.moveCaretUp))
      bind(.downArrow, to: .editing(.moveCaretDown))
      bind(.upArrow, modifiers: .shift, to: .editing(.selectCaretUp))
      bind(.downArrow, modifiers: .shift, to: .editing(.selectCaretDown))
      bind(.home, to: .editing(.moveCaretToStart))
      bind(.end, to: .editing(.moveCaretToEnd))
      bind(.enter, modifiers: shortcutModifier, to: ScribeComposerCommand.submit)
      bind(.enter, to: .editing(.submit))
      bind(.enter, modifiers: .shift, to: .editing(.submit))
      bind(.escape, to: .editing(.endEditing))
      bind(.space, to: .action(.activate))
      bind("f", to: ScribeCommandPickerCommand.previous)
      bind("j", to: ScribeCommandPickerCommand.next)
      bind(.tab, to: ScribeCommandPickerCommand.toggle)
    }
  }
}
