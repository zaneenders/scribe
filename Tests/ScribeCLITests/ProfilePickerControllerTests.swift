import SlateCore
import Testing

@testable import ScribeCLI

@MainActor
@Suite
struct ProfilePickerControllerTests {
  private let profiles = [
    ProfileSummary(name: "first", model: "model-1", baseURL: "https://one.example"),
    ProfileSummary(name: "second", model: "model-2", baseURL: "https://two.example"),
    ProfileSummary(name: "third", model: "model-3", baseURL: "https://three.example"),
  ]

  @Test func jMovesDownAndWraps() {
    let controller = ProfilePickerController()
    #expect(controller.open(profiles: profiles, activeName: "third", modelBusy: false))

    let effects = controller.handleInput(.character("j"))

    #expect(effects?.needsRender == true)
    #expect(controller.snapshot?.cursor == 0)
    #expect(controller.snapshot?.currentProfile.name == "first")
  }

  @Test func fMovesUpAndWraps() {
    let controller = ProfilePickerController()
    #expect(controller.open(profiles: profiles, activeName: "first", modelBusy: false))

    let effects = controller.handleInput(.character("f"))

    #expect(effects?.needsRender == true)
    #expect(controller.snapshot?.cursor == 2)
    #expect(controller.snapshot?.currentProfile.name == "third")
  }

  @Test func arrowKeysDoNotMoveSelection() {
    let controller = ProfilePickerController()
    #expect(controller.open(profiles: profiles, activeName: "second", modelBusy: false))

    let upEffects = controller.handleInput(.arrowUp)
    let downEffects = controller.handleInput(.arrowDown)

    #expect(upEffects?.needsRender == false)
    #expect(downEffects?.needsRender == false)
    #expect(controller.snapshot?.cursor == 1)
  }
}
