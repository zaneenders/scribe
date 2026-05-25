import Foundation
import Testing

@testable import ScribeCLI

@Suite
struct SubmitCoordinatorTests {

  @Test func enterWithTextWhenIdleSendsToGate() {
    let effect = SubmitCoordinator.handleEnter(
      text: "hello", modelBusy: false, steeringQueueCount: 0)
    #expect(effect == .sendToGate("hello"))
  }

  @Test func enterWithWhitespaceOnlyWhenIdleAndNothingQueuedIsNoOp() {
    let effect = SubmitCoordinator.handleEnter(
      text: "   ", modelBusy: false, steeringQueueCount: 0)
    #expect(effect == .none)
  }

  @Test func enterWithTextWhenBusyEnqueuesSteering() {
    let effect = SubmitCoordinator.handleEnter(
      text: "do thing", modelBusy: true, steeringQueueCount: 0)
    #expect(effect == .enqueueSteering("do thing"))
  }

  @Test func enterEmptyWhenBusyWithQueuedPopsAndInterrupts() {
    let effect = SubmitCoordinator.handleEnter(
      text: "", modelBusy: true, steeringQueueCount: 1)
    #expect(effect == .popAndInterruptAndSend)
  }

  @Test func enterEmptyWhenIdleWithQueuedPopsAndSends() {
    let effect = SubmitCoordinator.handleEnter(
      text: "", modelBusy: false, steeringQueueCount: 1)
    #expect(effect == .popAndSendToGate)
  }

  @Test func enterWhitespaceWhenIdleWithQueuedPopsAndSends() {
    let effect = SubmitCoordinator.handleEnter(
      text: "   ", modelBusy: false, steeringQueueCount: 1)
    #expect(effect == .popAndSendToGate)
  }

  @Test func ctrlCWithQueuedRecallsSteering() {
    let effect = SubmitCoordinator.handleCtrlC(steeringQueueCount: 2, modelBusy: true)
    #expect(effect == .recallSteeringToInput)
  }

  @Test func ctrlCWhenModelBusyNoQueuedInterruptsModel() {
    let effect = SubmitCoordinator.handleCtrlC(steeringQueueCount: 0, modelBusy: true)
    #expect(effect == .interruptModel)
  }

  @Test func ctrlCWhenIdleNoQueuedExitsChat() {
    let effect = SubmitCoordinator.handleCtrlC(steeringQueueCount: 0, modelBusy: false)
    #expect(effect == .exitChat)
  }

  @Test func followUpSubmitWhenBusyEnqueuesFollowUp() {
    let effect = SubmitCoordinator.handleFollowUpSubmit(text: "after done", modelBusy: true)
    #expect(effect == .enqueueFollowUp("after done"))
  }

  @Test func followUpSubmitWhenIdleSendsToGate() {
    let effect = SubmitCoordinator.handleFollowUpSubmit(text: "now", modelBusy: false)
    #expect(effect == .sendToGate("now"))
  }

  @Test func hostSideEffectsPopAndSendToGate() {
    let fx = HostSubmitSideEffects.from(.popAndSendToGate)
    #expect(fx.popSteeringToGate)
    #expect(fx.gateText == nil)
    #expect(fx.needsDelayedRenderWake)
  }

  @Test func hostSideEffectsEnqueueSteering() {
    let fx = HostSubmitSideEffects.from(.enqueueSteering("queued"))
    #expect(fx.enqueueSteering == "queued")
    #expect(fx.gateText == nil)
  }
}
