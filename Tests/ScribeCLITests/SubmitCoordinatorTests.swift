import Foundation
@testable import ScribeCLI
import Testing

// MARK: - SubmitCoordinator tests

/// Tests for the `SubmitCoordinator` state machine — pure functions of
/// `(state, event)` so they can be exercised without a running TUI.
@Suite
struct SubmitCoordinatorTests {

  // MARK: - Enter: model idle, non-empty buffer

  @Test func enterWithTextWhenIdleSendsToGate() {
    var c = SubmitCoordinator()
    c.setModelBusy(false)
    let effect = c.handleEnter(text: "hello")
    #expect(effect == .sendToGate("hello"))
  }

  @Test func enterWithWhitespaceOnlyWhenIdleAndNothingQueuedIsNoOp() {
    var c = SubmitCoordinator()
    c.setModelBusy(false)
    let effect = c.handleEnter(text: "   ")
    #expect(effect == .none)
  }

  // MARK: - Enter: model busy, non-empty buffer

  @Test func enterWithTextWhenBusySetsQueued() {
    var c = SubmitCoordinator()
    c.setModelBusy(true)
    let effect = c.handleEnter(text: "do thing")
    #expect(effect == .setQueued("do thing"))
    #expect(c.queuedText == "do thing")
  }

  // MARK: - Enter: empty buffer + queued tray

  @Test func enterEmptyWhenBusyWithQueuedInterruptsAndSends() {
    var c = SubmitCoordinator()
    c.setModelBusy(true)
    // First, queue something
    _ = c.handleEnter(text: "earlier")
    #expect(c.queuedText == "earlier")

    // Then empty-enter with busy model → interrupt-and-send
    let effect = c.handleEnter(text: "")
    #expect(effect == .interruptAndSend("earlier"))
    #expect(c.queuedText == nil)
  }

  @Test func enterEmptyWhenIdleWithQueuedSendsToGate() {
    var c = SubmitCoordinator()
    c.setModelBusy(true)
    _ = c.handleEnter(text: "queued msg")

    // Model becomes idle, then empty-enter
    c.setModelBusy(false)
    let effect = c.handleEnter(text: "")
    #expect(effect == .sendToGate("queued msg"))
    #expect(c.queuedText == nil)
  }

  @Test func enterWhitespaceWhenIdleWithQueuedSendsToGate() {
    var c = SubmitCoordinator()
    c.setModelBusy(true)
    _ = c.handleEnter(text: "queued msg")
    c.setModelBusy(false)
    // Whitespace-only is treated as empty
    let effect = c.handleEnter(text: "   ")
    #expect(effect == .sendToGate("queued msg"))
    #expect(c.queuedText == nil)
  }

  // MARK: - Ctrl+C ladder

  @Test func ctrlCWithQueuedRecallsText() {
    var c = SubmitCoordinator()
    c.setModelBusy(true)
    _ = c.handleEnter(text: "queued work")

    let (effect, recall) = c.handleCtrlC()
    #expect(effect == .clearQueued)
    #expect(recall == "queued work")
    #expect(c.queuedText == nil)
  }

  @Test func ctrlCWhenModelBusyNoQueuedInterruptsModel() {
    var c = SubmitCoordinator()
    c.setModelBusy(true)

    let (effect, recall) = c.handleCtrlC()
    #expect(effect == .interruptModel)
    #expect(recall == nil)
  }

  @Test func ctrlCWhenIdleNoQueuedExitsChat() {
    var c = SubmitCoordinator()
    c.setModelBusy(false)

    let (effect, recall) = c.handleCtrlC()
    #expect(effect == .exitChat)
    #expect(recall == nil)
  }

  // MARK: - Model turn end (auto-flush)

  @Test func modelTurnEndFlushesQueuedMessage() {
    var c = SubmitCoordinator()
    c.setModelBusy(true)
    _ = c.handleEnter(text: "next thing")

    // Model finishes → auto-flush
    c.setModelBusy(false)
    let effect = c.handleModelTurnEnd()
    #expect(effect == .sendToGate("next thing"))
    #expect(c.queuedText == nil)
  }

  @Test func modelTurnEndWhenNothingQueuedIsNoOp() {
    var c = SubmitCoordinator()
    c.setModelBusy(false)

    let effect = c.handleModelTurnEnd()
    #expect(effect == .none)
  }

  @Test func modelTurnEndWhenStillBusyDoesNotFlush() {
    var c = SubmitCoordinator()
    c.setModelBusy(true)
    _ = c.handleEnter(text: "patience")

    // Still busy — don't flush
    let effect = c.handleModelTurnEnd()
    #expect(effect == .none)
  }

  // MARK: - Queue overwrite

  @Test func secondQueuedMessageOverwritesFirst() {
    var c = SubmitCoordinator()
    c.setModelBusy(true)

    _ = c.handleEnter(text: "first")
    #expect(c.queuedText == "first")

    _ = c.handleEnter(text: "second")
    #expect(c.queuedText == "second")
  }
}
