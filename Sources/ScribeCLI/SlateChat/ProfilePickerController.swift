import Foundation
import Logging
import ScribeCore
import SlateCore
import SystemPackage

@MainActor
internal final class ProfilePickerController {

  private(set) var snapshot: ProfilePickerSnapshot?

  var logger: Logger = Logger(label: "scribe.profile-picker.unset")

  func handleInput(_ action: TerminalInputAction) -> ProfilePickerEffects? {
    guard var snap = snapshot else { return nil }
    switch action {
    case .character("f"):
      if !snap.profiles.isEmpty {
        snap.cursor = (snap.cursor - 1 + snap.profiles.count) % snap.profiles.count
        snapshot = snap
        return ProfilePickerEffects(needsRender: true)
      }
      return ProfilePickerEffects.none
    case .character("j"):
      if !snap.profiles.isEmpty {
        snap.cursor = (snap.cursor + 1) % snap.profiles.count
        snapshot = snap
        return ProfilePickerEffects(needsRender: true)
      }
      return ProfilePickerEffects.none
    case .arrowUp, .arrowDown:
      return ProfilePickerEffects.none
    case .enter:
      return confirm()
    case .escape, .ctrlC:
      return cancel()
    default:
      return nil
    }
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

  private func confirm() -> ProfilePickerEffects {
    guard let snap = snapshot else { return .none }
    let selected = snap.currentProfile
    let previousName = snap.activeName
    snapshot = nil
    return ProfilePickerEffects(
      needsRender: true,
      applyModel: ApplyModelRequest(name: selected.name, previousName: previousName))
  }

  private func cancel() -> ProfilePickerEffects {
    guard snapshot != nil else { return .none }
    snapshot = nil
    logger.debug("chat.profile-picker.cancel")
    return ProfilePickerEffects(needsRender: true)
  }
}
