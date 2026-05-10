import Foundation
import Testing

@testable import ScribeCLI

// MARK: - HostSubmitState tests

/// Tests for `HostSubmitState.apply` — the pure function that translates
/// `SubmitEffect` into host-side state mutations and side-effect descriptions.
///
/// These tests exist because the host's `applySubmitEffect` previously had a
/// bug where `queuedTrayText` wasn't cleared on `.sendToGate` and
/// `.interruptAndSend`, causing a "zombie" tray message that lingered in the
/// UI after the message had already been dispatched.
@Suite
struct HostSubmitStateTests {

  // MARK: - .sendToGate

  @Test func sendToGateClearsQueuedTrayText() {
    var state = HostSubmitState(queuedTrayText: "stale zombie text")
    let fx = HostSubmitState.apply(.sendToGate("hello"), to: &state)
    #expect(state.queuedTrayText == nil)
    #expect(fx.gateText == "hello")
    #expect(fx.needsDelayedRenderWake)
    #expect(fx.interruptLogTag == nil)
    #expect(fx.shouldExit == false)
  }

  @Test func sendToGateWhenTrayAlreadyNilStaysNil() {
    var state = HostSubmitState(queuedTrayText: nil)
    let fx = HostSubmitState.apply(.sendToGate("hello"), to: &state)
    #expect(state.queuedTrayText == nil)
    #expect(fx.gateText == "hello")
  }

  // MARK: - .interruptAndSend

  @Test func interruptAndSendClearsQueuedTrayText() {
    var state = HostSubmitState(queuedTrayText: "stale zombie text")
    let fx = HostSubmitState.apply(.interruptAndSend("urgent"), to: &state)
    #expect(state.queuedTrayText == nil)
    #expect(fx.gateText == "urgent")
    #expect(fx.interruptLogTag == "interrupt-and-send")
    #expect(fx.needsDelayedRenderWake)
    #expect(fx.shouldExit == false)
  }

  @Test func interruptAndSendWhenTrayAlreadyNilStaysNil() {
    var state = HostSubmitState(queuedTrayText: nil)
    let fx = HostSubmitState.apply(.interruptAndSend("urgent"), to: &state)
    #expect(state.queuedTrayText == nil)
    #expect(fx.gateText == "urgent")
  }

  // MARK: - .setQueued

  @Test func setQueuedStoresText() {
    var state = HostSubmitState(queuedTrayText: nil)
    let fx = HostSubmitState.apply(.setQueued("wait your turn"), to: &state)
    #expect(state.queuedTrayText == "wait your turn")
    #expect(fx.gateText == nil)
    #expect(fx.interruptLogTag == nil)
    #expect(fx.needsDelayedRenderWake == false)
    #expect(fx.shouldExit == false)
  }

  @Test func setQueuedOverwritesPreviousQueuedText() {
    var state = HostSubmitState(queuedTrayText: "old message")
    _ = HostSubmitState.apply(.setQueued("new message"), to: &state)
    #expect(state.queuedTrayText == "new message")
  }

  // MARK: - .clearQueued

  @Test func clearQueuedSetsTrayTextToNil() {
    var state = HostSubmitState(queuedTrayText: "something queued")
    let fx = HostSubmitState.apply(.clearQueued, to: &state)
    #expect(state.queuedTrayText == nil)
    #expect(fx.gateText == nil)
  }

  @Test func clearQueuedWhenAlreadyNilStaysNil() {
    var state = HostSubmitState(queuedTrayText: nil)
    _ = HostSubmitState.apply(.clearQueued, to: &state)
    #expect(state.queuedTrayText == nil)
  }

  // MARK: - .interruptModel

  @Test func interruptModelDoesNotChangeQueuedTrayText() {
    var state = HostSubmitState(queuedTrayText: nil)
    let fx = HostSubmitState.apply(.interruptModel, to: &state)
    #expect(state.queuedTrayText == nil)
    #expect(fx.interruptLogTag == "requested-by-ctrl-c")
    #expect(fx.gateText == nil)
    #expect(fx.needsDelayedRenderWake == false)
    #expect(fx.shouldExit == false)
  }

  @Test func interruptModelPreservesExistingQueuedText() {
    // Interrupting the model shouldn't touch the tray — that's handled
    // separately by the Ctrl+C recall logic in the host.
    var state = HostSubmitState(queuedTrayText: "still queued")
    let fx = HostSubmitState.apply(.interruptModel, to: &state)
    #expect(state.queuedTrayText == "still queued")
    #expect(fx.interruptLogTag == "requested-by-ctrl-c")
  }

  // MARK: - .exitChat

  @Test func exitChatSetsShouldExit() {
    var state = HostSubmitState(queuedTrayText: nil)
    let fx = HostSubmitState.apply(.exitChat, to: &state)
    #expect(fx.shouldExit)
    #expect(state.queuedTrayText == nil)
    #expect(fx.gateText == nil)
    #expect(fx.needsDelayedRenderWake == false)
  }

  // MARK: - .none

  @Test func noneIsNoOp() {
    var state = HostSubmitState(queuedTrayText: "keep me")
    let fx = HostSubmitState.apply(.none, to: &state)
    #expect(state.queuedTrayText == "keep me")
    #expect(fx == HostSubmitState.SideEffects())
  }

  // MARK: - Invariant: no effect leaves queuedTrayText non-nil when it should be nil

  @Test func allEffectsProduceConsistentState() {
    /// The key invariant: if the effect dispatches text to the gate
    /// (meaning the queued message is consumed), `queuedTrayText` must be nil.
    let consumingEffects: [SubmitEffect] = [
      .sendToGate("a"),
      .interruptAndSend("b"),
    ]
    for effect in consumingEffects {
      var state = HostSubmitState(queuedTrayText: "zombie bait")
      _ = HostSubmitState.apply(effect, to: &state)
      #expect(
        state.queuedTrayText == nil,
        "\(effect) must clear queuedTrayText")
    }

    /// Effects that set or clear the tray explicitly should do so correctly.
    var state = HostSubmitState(queuedTrayText: nil)
    _ = HostSubmitState.apply(.setQueued("hello"), to: &state)
    #expect(state.queuedTrayText == "hello")

    _ = HostSubmitState.apply(.clearQueued, to: &state)
    #expect(state.queuedTrayText == nil)
  }

  // MARK: - Idempotency of clear operations

  @Test func doubleClearIsHarmless() {
    var state = HostSubmitState(queuedTrayText: "msg")
    _ = HostSubmitState.apply(.clearQueued, to: &state)
    #expect(state.queuedTrayText == nil)
    // Second clear should not crash or change anything.
    _ = HostSubmitState.apply(.clearQueued, to: &state)
    #expect(state.queuedTrayText == nil)
  }

  @Test func sendToGateAfterClearIsHarmless() {
    var state = HostSubmitState(queuedTrayText: nil)
    let fx = HostSubmitState.apply(.sendToGate("after clear"), to: &state)
    #expect(state.queuedTrayText == nil)
    #expect(fx.gateText == "after clear")
  }
}
