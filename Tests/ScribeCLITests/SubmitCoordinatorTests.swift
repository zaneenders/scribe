import Foundation
import Testing

@testable import ScribeCLI
@testable import ScribeKit

@Suite
struct SubmitCoordinatorTests {

  @Test func enterWithTextWhenIdleSendsToGate() {
    let effect = SubmitCoordinator.handleEnter(
      text: "hello", modelBusy: false, queueCount: 0, queuedLineOutstanding: false)
    #expect(effect == .sendToGate("hello"))
  }

  @Test func enterWithWhitespaceOnlyWhenIdleAndNothingQueuedIsNoOp() {
    let effect = SubmitCoordinator.handleEnter(
      text: "   ", modelBusy: false, queueCount: 0, queuedLineOutstanding: false)
    #expect(effect == .none)
  }

  @Test func enterWithTextWhenBusyEnqueues() {
    let effect = SubmitCoordinator.handleEnter(
      text: "do thing", modelBusy: true, queueCount: 0, queuedLineOutstanding: false)
    #expect(effect == .enqueue("do thing"))
  }

  @Test func enterEmptyWhenBusyWithQueuedOnlyInterrupts() {
    let effect = SubmitCoordinator.handleEnter(
      text: "", modelBusy: true, queueCount: 4, queuedLineOutstanding: false)
    #expect(effect == .interruptModel)
  }

  @Test func enterEmptyWhenBusyWithQueuedDoesNotPop() {
    let effect = SubmitCoordinator.handleEnter(
      text: "", modelBusy: true, queueCount: 1, queuedLineOutstanding: false)
    #expect(effect != .popAndInterruptAndSend)
    #expect(effect != .popAndSendToGate)
  }

  @Test func enterEmptyWhenIdleWithQueuedPopsAndSends() {
    let effect = SubmitCoordinator.handleEnter(
      text: "", modelBusy: false, queueCount: 1, queuedLineOutstanding: false)
    #expect(effect == .popAndSendToGate)
  }

  @Test func enterEmptyWhenOutstandingAndIdleIsNoOp() {
    let effect = SubmitCoordinator.handleEnter(
      text: "", modelBusy: false, queueCount: 2, queuedLineOutstanding: true)
    #expect(effect == .none)
  }

  @Test func ctrlCWithQueuedRecallsMessage() {
    let effect = SubmitCoordinator.handleCtrlC(queueCount: 2, modelBusy: true)
    #expect(effect == .recallQueuedToInput)
  }

}
