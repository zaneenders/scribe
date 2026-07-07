import Foundation
import Logging
import ScribeCore
import SlateCore
import SystemPackage

@MainActor
internal final class ProfilePickerController {

  private(set) var snapshot: ProfilePickerSnapshot?

  weak var host: (any ProfilePickerHost)?
  var logger: Logger = Logger(label: "scribe.profile-picker.unset")
  var theme: CLITheme = .default
  var paths: ScribePaths = ScribePaths(dataHome: FilePath("/"))

  func handleInput(_ action: TerminalInputAction) -> Bool {
    guard var snap = snapshot else { return false }
    switch action {
    case .arrowUp:
      if !snap.profiles.isEmpty {
        snap.cursor = (snap.cursor - 1 + snap.profiles.count) % snap.profiles.count
        snapshot = snap
        host?.requestRender()
      }
    case .arrowDown:
      if !snap.profiles.isEmpty {
        snap.cursor = (snap.cursor + 1) % snap.profiles.count
        snapshot = snap
        host?.requestRender()
      }
    case .enter:
      confirm()
    case .escape, .ctrlC:
      cancel()
    default:
      return false
    }
    return true
  }

  func open(profiles: [ProfileSummary], activeName: String, modelBusy: Bool) -> Bool {
    if modelBusy {
      logger.notice("chat.profile-picker.open.skip", metadata: ["reason": "model-busy"])
      return false
    }
    guard !profiles.isEmpty else {
      logger.notice("chat.profile-picker.open.skip", metadata: ["reason": "no-profiles"])
      return false
    }
    let cursor = profiles.firstIndex(where: { $0.name == activeName }) ?? 0
    snapshot = ProfilePickerSnapshot(
      profiles: profiles,
      cursor: cursor,
      activeName: activeName)
    logger.notice(
      "chat.profile-picker.open",
      metadata: [
        "count": "\(profiles.count)",
        "active": "\(activeName)",
      ])
    return true
  }

  func clear() {
    snapshot = nil
  }

  private func confirm() {
    guard let snap = snapshot else { return }
    let selected = snap.currentProfile
    let previousName = snap.activeName
    snapshot = nil
    Task { @MainActor in
      await self.host?.applyBackendProfile(selected.name, previousName: previousName)
      self.host?.requestRender()
    }
  }

  private func cancel() {
    guard snapshot != nil else { return }
    snapshot = nil
    logger.debug("chat.profile-picker.cancel")
    host?.requestRender()
  }
}

@MainActor
internal protocol ProfilePickerHost: AnyObject {
  func requestRender()
  func appendProfilePickerNotice(_ text: String)
  func applyBackendProfile(_ name: String, previousName: String) async
}
