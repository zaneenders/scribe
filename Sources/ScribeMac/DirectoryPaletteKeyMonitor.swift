#if canImport(AppKit)
import AppKit
import Chroma

/// Handles app-specific editing shortcuts before Chroma translates key events.
@MainActor
final class DirectoryPaletteKeyMonitor {
  static let shared = DirectoryPaletteKeyMonitor()

  private var monitor: Any?
  var onTab: (() -> Void)?
  var onEscape: (() -> Void)?
  var onComposerSubmit: (() -> Void)?
  var onComposerStop: (() -> Bool)?
  var onComposerHistoryPrevious: (() -> Bool)?
  var onComposerHistoryNext: (() -> Bool)?
  var onCommandPickerMove: ((Int) -> Void)?
  var onCommandPickerToggle: (() -> Void)?
  var onCommandPickerConfirm: (() -> Void)?
  var onCommandPickerCancel: (() -> Void)?
  var copyText: (() -> String?)?

  private init() {}

  func install() {
    guard monitor == nil else { return }
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      if event.modifierFlags.contains(.command),
        event.charactersIgnoringModifiers?.lowercased() == "c",
        let text = self?.copyText?(),
        !text.isEmpty
      {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return nil
      }
      let store = ScribeMacStore.shared
      if store.showDirectoryPicker {
        if event.keyCode == 48 {
          self?.onTab?()
          return nil
        }
        if event.keyCode == 53 {
          self?.onEscape?()
          return nil
        }
        return event
      }
      if store.active?.commandPicker != nil {
        switch event.keyCode {
        case 3:  // f
          self?.onCommandPickerMove?(-1)
          return nil
        case 38:  // j
          self?.onCommandPickerMove?(1)
          return nil
        case 48:  // Tab
          self?.onCommandPickerToggle?()
          return nil
        case 36, 76:  // Return / keypad Enter
          self?.onCommandPickerConfirm?()
          return nil
        case 53:  // Escape
          self?.onCommandPickerCancel?()
          return nil
        default:
          return event
        }
      }
      // Chroma's command routing is focus-scoped. A pointer move over the tab bar can
      // move that focus away from the terminal even though the Terminal tab remains
      // active, causing cursor keys to be dropped before they reach the PTY. Route
      // shell history keys directly while the terminal pane is on screen.
      if let session = store.active, session.selectedTab == .terminal,
        let terminal = session.terminal
      {
        switch event.keyCode {
        case 126:  // Up
          terminal.send(key: .arrowUp)
          return nil
        case 125:  // Down
          terminal.send(key: .arrowDown)
          return nil
        default:
          break
        }
      }
      guard ScribeRenderContext.activeTextInput == ScribeMacStore.composerID, store.active != nil else {
        return event
      }
      switch event.keyCode {
      case 36, 76:  // Return / keypad Enter
        guard event.modifierFlags.contains(.command) else { return event }
        self?.onComposerSubmit?()
        return nil
      case 53:  // Escape
        return self?.onComposerStop?() == true ? nil : event
      case 126:  // Up
        return self?.onComposerHistoryPrevious?() == true ? nil : event
      case 125:  // Down
        return self?.onComposerHistoryNext?() == true ? nil : event
      default:
        return event
      }
    }
  }

  func uninstall() {
    if let monitor {
      NSEvent.removeMonitor(monitor)
    }
    monitor = nil
    onTab = nil
    onEscape = nil
    onComposerSubmit = nil
    onComposerStop = nil
    onComposerHistoryPrevious = nil
    onComposerHistoryNext = nil
    onCommandPickerMove = nil
    onCommandPickerToggle = nil
    onCommandPickerConfirm = nil
    onCommandPickerCancel = nil
    copyText = nil
  }
}
#endif
