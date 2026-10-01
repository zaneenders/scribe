import Chroma

@MainActor
public final class ScribeWorkspace {
  let store: ScribeMacStore

  init(store: ScribeMacStore) { self.store = store }

  public init() {
    store = ScribeMacStore(startProfiling: false)
  }
}

public struct ScribeBlock: Block {
  private let workspace: ScribeWorkspace?

  public init() {
    workspace = nil
  }

  public init(workspace: ScribeWorkspace) {
    self.workspace = workspace
  }

  @MainActor public var body: some Block {
    let store = workspace?.store ?? ScribeMacStore.shared
    store.start()
    return ThemeReader { chromaTheme in
      ScribeMacRoot(store: store, theme: MacTheme(chromaTheme: chromaTheme))
        .chromaTheme(chromaTheme)
    }
  }
}

enum ScribeComposerCommand {
  static let submit: Command = .application("scribe.composer.submit")

  @MainActor static func shouldSubmit(_ command: Command, composerFocus: FocusTarget) -> Bool {
    command == submit && composerFocus.isEditing
  }
}

enum ScribeCommandPickerCommand {
  static let previous: Command = .application("scribe.command-picker.previous")
  static let toggle: Command = .application("scribe.command-picker.toggle")
  static let next: Command = .application("scribe.command-picker.next")

  static let keyBindings = KeyBindings {
    bind("f", to: previous)
    bind("j", to: next)
    bind(.tab, in: .shared, to: toggle)
  }
}

extension ScribeBlock {
  public static var submitCommand: Command { ScribeComposerCommand.submit }

  public static var keyBindings: KeyBindings {
    #if os(macOS)
    let shortcutModifier = KeyModifiers.command
    #elseif os(Linux)
    let shortcutModifier = KeyModifiers.superKey
    #else
    let shortcutModifier = KeyModifiers.control
    #endif

    return KeyBindings.desktopNavigation.overlay(.modalNavigation).overlay {
      disable(.upArrow, in: .movement)
      disable(.downArrow, in: .movement)
      disable(.leftArrow, in: .movement)
      disable(.rightArrow, in: .movement)
      disable(.upArrow, in: .editing)
      disable(.downArrow, in: .editing)
      disable(.leftArrow, in: .editing)
      disable(.rightArrow, in: .editing)
      bind("d", modifiers: .control, to: .navigation(.sectionLeft))
      bind("f", modifiers: .control, to: .navigation(.sectionUp))
      bind("j", modifiers: .control, to: .navigation(.sectionDown))
      bind("k", modifiers: .control, to: .navigation(.sectionRight))
      disable("d", modifiers: .shift, in: .movement)
      disable("f", modifiers: .shift, in: .movement)
      disable("j", modifiers: .shift, in: .movement)
      disable("k", modifiers: .shift, in: .movement)
      bind("d", modifiers: .control, in: .editing, to: .navigation(.sectionLeft))
      bind("f", modifiers: .control, in: .editing, to: .navigation(.sectionUp))
      bind("j", modifiers: .control, in: .editing, to: .navigation(.sectionDown))
      bind("k", modifiers: .control, in: .editing, to: .navigation(.sectionRight))
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
      bind(.enter, modifiers: shortcutModifier, to: ScribeComposerCommand.submit)
      bind(.enter, to: .editing(.submit))
      bind(.enter, modifiers: .shift, to: .editing(.submit))
    }
  }
}
