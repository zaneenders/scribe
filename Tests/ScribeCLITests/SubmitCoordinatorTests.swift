import Foundation
import Testing

@testable import ScribeCLI

@Suite
struct SubmitCoordinatorTests {

  @Test func enterWithTextWhenIdleSendsToGate() {
    let effect = SubmitCoordinator.handleEnter(
      text: "hello", modelBusy: false, steeringQueueCount: 0, steeringLineOutstanding: false)
    #expect(effect == .sendToGate("hello"))
  }

  @Test func enterWithWhitespaceOnlyWhenIdleAndNothingQueuedIsNoOp() {
    let effect = SubmitCoordinator.handleEnter(
      text: "   ", modelBusy: false, steeringQueueCount: 0, steeringLineOutstanding: false)
    #expect(effect == .none)
  }

  @Test func enterWithTextWhenBusyEnqueuesSteering() {
    let effect = SubmitCoordinator.handleEnter(
      text: "do thing", modelBusy: true, steeringQueueCount: 0, steeringLineOutstanding: false)
    #expect(effect == .enqueueSteering("do thing"))
  }

  @Test func enterEmptyWhenBusyWithQueuedOnlyInterrupts() {
    let effect = SubmitCoordinator.handleEnter(
      text: "", modelBusy: true, steeringQueueCount: 4, steeringLineOutstanding: false)
    #expect(effect == .interruptModel)
  }

  @Test func enterEmptyWhenBusyWithQueuedDoesNotPop() {
    let effect = SubmitCoordinator.handleEnter(
      text: "", modelBusy: true, steeringQueueCount: 1, steeringLineOutstanding: false)
    #expect(effect != .popAndInterruptAndSend)
    #expect(effect != .popAndSendToGate)
  }

  @Test func enterEmptyWhenIdleWithQueuedPopsAndSends() {
    let effect = SubmitCoordinator.handleEnter(
      text: "", modelBusy: false, steeringQueueCount: 1, steeringLineOutstanding: false)
    #expect(effect == .popAndSendToGate)
  }

  @Test func enterEmptyWhenOutstandingAndIdleIsNoOp() {
    let effect = SubmitCoordinator.handleEnter(
      text: "", modelBusy: false, steeringQueueCount: 2, steeringLineOutstanding: true)
    #expect(effect == .none)
  }

  @Test func ctrlCWithQueuedRecallsSteering() {
    let effect = SubmitCoordinator.handleCtrlC(steeringQueueCount: 2, modelBusy: true)
    #expect(effect == .recallSteeringToInput)
  }

}
