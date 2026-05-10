import Foundation
import Testing

@testable import ScribeCLI

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

  @Test func enterWithTextWhenBusyAppendsToQueue() {
    var c = SubmitCoordinator()
    c.setModelBusy(true)
    let effect = c.handleEnter(text: "do thing")
    #expect(effect == .setQueued(["do thing"]))
    #expect(c.queuedTexts == ["do thing"])
  }

  // MARK: - Enter: empty buffer + queued tray

  @Test func enterEmptyWhenBusyWithQueuedInterruptsAndSends() {
    var c = SubmitCoordinator()
    c.setModelBusy(true)
    // First, queue something
    _ = c.handleEnter(text: "earlier")
    #expect(c.queuedTexts == ["earlier"])

    // Then empty-enter with busy model → interrupt-and-send
    let effect = c.handleEnter(text: "")
    #expect(effect == .interruptAndSend("earlier"))
    #expect(c.queuedTexts == [])
  }

  @Test func enterEmptyWhenIdleWithQueuedSendsToGate() {
    var c = SubmitCoordinator()
    c.setModelBusy(true)
    _ = c.handleEnter(text: "queued msg")

    // Model becomes idle, then empty-enter
    c.setModelBusy(false)
    let effect = c.handleEnter(text: "")
    #expect(effect == .sendToGate("queued msg"))
    #expect(c.queuedTexts == [])
  }

  @Test func enterWhitespaceWhenIdleWithQueuedSendsToGate() {
    var c = SubmitCoordinator()
    c.setModelBusy(true)
    _ = c.handleEnter(text: "queued msg")
    c.setModelBusy(false)
    // Whitespace-only is treated as empty
    let effect = c.handleEnter(text: "   ")
    #expect(effect == .sendToGate("queued msg"))
    #expect(c.queuedTexts == [])
  }

  // MARK: - Ctrl+C ladder

  @Test func ctrlCWithQueuedRecallsFirstText() {
    var c = SubmitCoordinator()
    c.setModelBusy(true)
    _ = c.handleEnter(text: "first")
    _ = c.handleEnter(text: "second")

    // Recall pops oldest (FIFO)
    let (effect, recall) = c.handleCtrlC()
    #expect(effect == .clearQueued(["second"]))
    #expect(recall == "first")
    #expect(c.queuedTexts == ["second"])
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

  @Test func modelTurnEndFlushesAllQueuedMessages() {
    var c = SubmitCoordinator()
    c.setModelBusy(true)
    _ = c.handleEnter(text: "first")
    _ = c.handleEnter(text: "second")
    _ = c.handleEnter(text: "third")

    // Model finishes → auto-flush all
    c.setModelBusy(false)
    let drained = c.handleModelTurnEnd()
    #expect(drained == ["first", "second", "third"])
    #expect(c.queuedTexts == [])
  }

  @Test func modelTurnEndWhenNothingQueuedReturnsEmpty() {
    var c = SubmitCoordinator()
    c.setModelBusy(false)

    let drained = c.handleModelTurnEnd()
    #expect(drained == [])
  }

  @Test func modelTurnEndWhenStillBusyReturnsEmpty() {
    var c = SubmitCoordinator()
    c.setModelBusy(true)
    _ = c.handleEnter(text: "patience")

    // Still busy — don't flush
    let drained = c.handleModelTurnEnd()
    #expect(drained == [])
  }

  // MARK: - Queue FIFO append

  @Test func multipleQueuedMessagesAppendFIFO() {
    var c = SubmitCoordinator()
    c.setModelBusy(true)

    _ = c.handleEnter(text: "first")
    _ = c.handleEnter(text: "second")
    _ = c.handleEnter(text: "third")
    #expect(c.queuedTexts == ["first", "second", "third"])

    // Empty enter pops oldest (FIFO)
    let effect = c.handleEnter(text: "")
    #expect(effect == .interruptAndSend("first"))
    #expect(c.queuedTexts == ["second", "third"])
  }

  // MARK: - Enter: trim whitespace

  @Test func enterWhitespaceOnlyBusyNoQueueIsNoOp() {
    var c = SubmitCoordinator()
    c.setModelBusy(true)
    let effect = c.handleEnter(text: "   ")
    #expect(effect == .none)
    #expect(c.queuedTexts == [])
  }

  @Test func enterOnlyNewlineBusyNoQueueIsNoOp() {
    var c = SubmitCoordinator()
    c.setModelBusy(true)
    let effect = c.handleEnter(text: "\n")
    #expect(effect == .none)
    #expect(c.queuedTexts == [])
  }
}
