import Chroma

/// The embeddable Scribe macOS interface.
///
/// Hosts can place this block anywhere in a larger Chroma hierarchy. Scribe
/// retains its own session store, so switching a host-level tab does not stop
/// turns that are running in the background.
public struct ScribeBlock: Block {
  public init() {}

  @MainActor public var body: some Block {
    let store = ScribeMacStore.shared
    store.start()
    return ScribeMacRoot(store: store)
  }
}

enum ScribeCommandPickerCommand {
  static let previous: Command = .application("scribe.command-picker.previous")
  static let next: Command = .application("scribe.command-picker.next")
}

extension ScribeBlock {
  /// Recommended editing and navigation bindings for a host Chroma app.
  public static var keyBindings: KeyBindings {
    KeyBindings {
      bind("c", modifiers: .command, to: .editing(.copy))
      bind("v", modifiers: .command, to: .editing(.paste))
      bind("a", modifiers: .command, to: .editing(.selectAll))
      bind(.backspace, to: .editing(.backspace))
      bind(.delete, to: .editing(.deleteForward))
      bind(.leftArrow, to: .editing(.moveCaretLeft))
      bind(.rightArrow, to: .editing(.moveCaretRight))
      bind(.home, to: .editing(.moveCaretToStart))
      bind(.end, to: .editing(.moveCaretToEnd))
      bind(.enter, to: .editing(.submit))
      bind(.enter, modifiers: .shift, to: .editing(.submit))
      bind(.escape, to: .editing(.endEditing))
      bind(.space, to: .action(.activate))
      bind(.pageUp, to: .navigation(.pageUp))
      bind(.pageDown, to: .navigation(.pageDown))
      // Fork/TLDR picker commands. Their handlers are scoped to the ready layout,
      // so these remain inert whenever no picker is open.
      bind("f", to: ScribeCommandPickerCommand.previous)
      bind("j", to: ScribeCommandPickerCommand.next)
      // Terminal tab: routed by focus scope, inert outside it.
      bind("c", modifiers: .control, to: ScribeTerminalCommand.interrupt)
      bind("/", modifiers: .control, to: ScribeTerminalCommand.controlSlash)
      // Ctrl-/ and Ctrl-_ share the terminal byte 0x1F; accept either chord.
      bind("_", modifiers: .control, to: ScribeTerminalCommand.controlSlash)
      bind(.tab, to: ScribeTerminalCommand.complete)
      bind(.upArrow, to: ScribeTerminalCommand.lineUp)
      bind(.downArrow, to: ScribeTerminalCommand.lineDown)
    }
  }
}
