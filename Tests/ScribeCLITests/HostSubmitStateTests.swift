import Foundation
import Testing

@testable import ScribeCLI

@Suite
struct HostSubmitSideEffectsTests {

  @Test func sendToGateSetsGateText() {
    let fx = HostSubmitSideEffects.from(.sendToGate("hello"))
    #expect(fx.gateText == "hello")
    #expect(fx.needsDelayedRenderWake)
    #expect(fx.interruptLogTag == nil)
    #expect(fx.shouldExit == false)
  }

  @Test func interruptAndSendSetsInterruptTag() {
    let fx = HostSubmitSideEffects.from(.interruptAndSend("urgent"))
    #expect(fx.gateText == "urgent")
    #expect(fx.interruptLogTag == "interrupt-and-send")
    #expect(fx.needsDelayedRenderWake)
  }

  @Test func popAndInterruptAndSendSetsPopAndInterrupt() {
    let fx = HostSubmitSideEffects.from(.popAndInterruptAndSend)
    #expect(fx.popSteeringToGate)
    #expect(fx.interruptLogTag == "interrupt-and-send")
  }

  @Test func recallSteeringToInputSetsFlag() {
    let fx = HostSubmitSideEffects.from(.recallSteeringToInput)
    #expect(fx.recallSteeringToInput)
  }

  @Test func enqueueSteeringSetsSideEffect() {
    let fx = HostSubmitSideEffects.from(.enqueueSteering("wait your turn"))
    #expect(fx.enqueueSteering == "wait your turn")
    #expect(fx.gateText == nil)
  }

  @Test func interruptModelRequestsInterrupt() {
    let fx = HostSubmitSideEffects.from(.interruptModel)
    #expect(fx.interruptLogTag == "requested-by-ctrl-c")
  }

  @Test func exitChatSetsShouldExit() {
    let fx = HostSubmitSideEffects.from(.exitChat)
    #expect(fx.shouldExit)
  }

  @Test func noneIsNoOp() {
    let fx = HostSubmitSideEffects.from(.none)
    #expect(fx == HostSubmitSideEffects())
  }
}
