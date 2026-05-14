import Foundation
import Testing

@testable import ScribeCLI

// MARK: - HostSubmitState tests

/// Tests for `HostSubmitState.apply` — the pure function that translates
/// `SubmitEffect` into host-side state mutations and side-effect descriptions.
///
/// These tests exist because the host's `applySubmitEffect` previously had a
/// bug where `queuedTrayTexts` wasn't cleared on `.sendToGate` and
/// `.interruptAndSend`, causing a "zombie" tray message that lingered in the
/// UI after the message had already been dispatched.
@Suite
struct HostSubmitStateTests {

  // MARK: - .sendToGate

  @Test func sendToGatePreservesEmptyTray() {
    var state = HostSubmitState(queuedTrayTexts: ["stale zombie text"])
    let fx = HostSubmitState.apply(.sendToGate("hello"), to: &state)
    #expect(state.queuedTrayTexts == ["stale zombie text"])  // sendToGate doesn't clear the tray
    #expect(fx.gateText == "hello")
    #expect(fx.needsDelayedRenderWake)
    #expect(fx.interruptLogTag == nil)
    #expect(fx.shouldExit == false)
  }

  @Test func sendToGateWhenTrayAlreadyEmpty() {
    var state = HostSubmitState(queuedTrayTexts: [])
    let fx = HostSubmitState.apply(.sendToGate("hello"), to: &state)
    #expect(state.queuedTrayTexts == [])
    #expect(fx.gateText == "hello")
  }

  // MARK: - .interruptAndSend

  @Test func interruptAndSendPreservesTrayState() {
    var state = HostSubmitState(queuedTrayTexts: ["stale zombie text"])
    let fx = HostSubmitState.apply(.interruptAndSend("urgent"), to: &state)
    #expect(state.queuedTrayTexts == ["stale zombie text"])  // interruptAndSend doesn't clear tray on its own
    #expect(fx.gateText == "urgent")
    #expect(fx.interruptLogTag == "interrupt-and-send")
    #expect(fx.needsDelayedRenderWake)
    #expect(fx.shouldExit == false)
  }

  @Test func interruptAndSendWhenTrayAlreadyEmpty() {
    var state = HostSubmitState(queuedTrayTexts: [])
    let fx = HostSubmitState.apply(.interruptAndSend("urgent"), to: &state)
    #expect(state.queuedTrayTexts == [])
    #expect(fx.gateText == "urgent")
  }

  // MARK: - .setQueued

  @Test func setQueuedStoresTexts() {
    var state = HostSubmitState(queuedTrayTexts: [])
    let fx = HostSubmitState.apply(.setQueued(["wait your turn"]), to: &state)
    #expect(state.queuedTrayTexts == ["wait your turn"])
    #expect(fx.gateText == nil)
    #expect(fx.interruptLogTag == nil)
    #expect(fx.needsDelayedRenderWake == false)
    #expect(fx.shouldExit == false)
  }

  @Test func setQueuedReplacesAll() {
    var state = HostSubmitState(queuedTrayTexts: ["old message"])
    _ = HostSubmitState.apply(.setQueued(["new message", "another"]), to: &state)
    #expect(state.queuedTrayTexts == ["new message", "another"])
  }

  // MARK: - .clearQueued

  @Test func clearQueuedUpdatesTrayTexts() {
    var state = HostSubmitState(queuedTrayTexts: ["something queued", "more"])
    let fx = HostSubmitState.apply(.clearQueued(["more"]), to: &state)
    #expect(state.queuedTrayTexts == ["more"])
    #expect(fx.gateText == nil)
  }

  @Test func clearQueuedWhenAlreadyEmpty() {
    var state = HostSubmitState(queuedTrayTexts: [])
    _ = HostSubmitState.apply(.clearQueued([]), to: &state)
    #expect(state.queuedTrayTexts == [])
  }

  // MARK: - .interruptModel

  @Test func interruptModelDoesNotChangeQueuedTrayTexts() {
    var state = HostSubmitState(queuedTrayTexts: [])
    let fx = HostSubmitState.apply(.interruptModel, to: &state)
    #expect(state.queuedTrayTexts == [])
    #expect(fx.interruptLogTag == "requested-by-ctrl-c")
    #expect(fx.gateText == nil)
    #expect(fx.needsDelayedRenderWake == false)
    #expect(fx.shouldExit == false)
  }

  @Test func interruptModelPreservesExistingQueuedTexts() {
    // Interrupting the model shouldn't touch the tray — that's handled
    // separately by the Ctrl+C recall logic in the host.
    var state = HostSubmitState(queuedTrayTexts: ["still queued"])
    let fx = HostSubmitState.apply(.interruptModel, to: &state)
    #expect(state.queuedTrayTexts == ["still queued"])
    #expect(fx.interruptLogTag == "requested-by-ctrl-c")
  }

  // MARK: - .exitChat

  @Test func exitChatSetsShouldExit() {
    var state = HostSubmitState(queuedTrayTexts: [])
    let fx = HostSubmitState.apply(.exitChat, to: &state)
    #expect(fx.shouldExit)
    #expect(state.queuedTrayTexts == [])
    #expect(fx.gateText == nil)
    #expect(fx.needsDelayedRenderWake == false)
  }

  // MARK: - .none

  @Test func noneIsNoOp() {
    var state = HostSubmitState(queuedTrayTexts: ["keep me"])
    let fx = HostSubmitState.apply(.none, to: &state)
    #expect(state.queuedTrayTexts == ["keep me"])
    #expect(fx == HostSubmitState.SideEffects())
  }

  // MARK: - Idempotency of clear operations

  @Test func doubleClearIsHarmless() {
    var state = HostSubmitState(queuedTrayTexts: ["msg", "another"])
    _ = HostSubmitState.apply(.clearQueued(["another"]), to: &state)
    #expect(state.queuedTrayTexts == ["another"])
    // Second clear should not crash or change anything unexpected.
    _ = HostSubmitState.apply(.clearQueued([]), to: &state)
    #expect(state.queuedTrayTexts == [])
  }

  @Test func sendToGateAfterClearIsHarmless() {
    var state = HostSubmitState(queuedTrayTexts: [])
    let fx = HostSubmitState.apply(.sendToGate("after clear"), to: &state)
    #expect(state.queuedTrayTexts == [])
    #expect(fx.gateText == "after clear")
  }
}
