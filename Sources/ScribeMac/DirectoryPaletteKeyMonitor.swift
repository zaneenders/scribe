#if canImport(AppKit)
import AppKit
import Chroma

/// Consumes Tab while the directory palette owns keyboard focus.
@MainActor
final class DirectoryPaletteKeyMonitor {
  static let shared = DirectoryPaletteKeyMonitor()

  private var monitor: Any?
  var onTab: (() -> Void)?
  var onEscape: (() -> Void)?

  private init() {}

  func install() {
    guard monitor == nil else { return }
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard Interaction.current.isTextEditing,
        Interaction.current.editingLeaf == ScribeMacStore.directoryPaletteID
      else {
        return event
      }
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
  }

  func uninstall() {
    if let monitor {
      NSEvent.removeMonitor(monitor)
    }
    monitor = nil
    onTab = nil
    onEscape = nil
  }
}
#endif
