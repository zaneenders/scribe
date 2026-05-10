// MARK: - SubmitCoordinator

/// Effects the host must perform in response to a submit action.
/// Each case maps to exactly one host-side operation — no ambiguity.
enum SubmitEffect: Equatable, Sendable {
  /// Send text to the coordinator via `UserLineGate` (model is idle).
  case sendToGate(String)
  /// Interrupt the model AND send text to the gate (empty Enter with queued message).
  case interruptAndSend(String)
  /// Park text in the queued tray (model is busy).
  case setQueued(String)
  /// Remove any queued tray text.
  case clearQueued
  /// Request an interrupt of the in-flight model turn.
  case interruptModel
  /// Stop the chat loop (Ctrl+C on idle, Ctrl+D, EOF).
  case exitChat
  /// No state change needed.
  case none
}

/// Owns the queued-submission tray and the Ctrl+C "ladder" state machine.
///
/// All state transitions are pure functions of `(currentState, event)` so
/// they can be unit-tested without a running TUI.
struct SubmitCoordinator {
  /// Whether model turn is busy (set by host before calling into coordinator).
  private var modelBusy: Bool = false
  /// Text parked in the queued tray while the model is busy, if any.
  private(set) var queuedText: String? = nil

  // MARK: - Inputs from host

  /// Call before `handleEnter` / `handleCtrlC` so the coordinator knows
  /// whether the model is currently processing a turn.
  mutating func setModelBusy(_ busy: Bool) {
    modelBusy = busy
  }

  // MARK: - Enter key

  /// User pressed Enter with `text` in the input buffer.
  mutating func handleEnter(text: String) -> SubmitEffect {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

    if trimmed.isEmpty {
      // Empty buffer + queued tray → interrupt-and-send.
      guard let queued = queuedText else {
        return .none  // Empty buffer, nothing queued → no-op.
      }
      queuedText = nil
      if modelBusy {
        return .interruptAndSend(queued)
      }
      return .sendToGate(queued)
    }

    if modelBusy {
      queuedText = text
      return .setQueued(text)
    }

    return .sendToGate(text)
  }

  // MARK: - Ctrl+C ladder

  /// Three-step ladder, evaluated in order:
  /// 1. Queued message present → recall it to input buffer.
  /// 2. Model is busy → request interrupt.
  /// 3. Model is idle, nothing queued → exit chat.
  mutating func handleCtrlC() -> (effect: SubmitEffect, recallText: String?) {
    if let queued = queuedText {
      queuedText = nil
      return (.clearQueued, queued)
    }
    if modelBusy {
      return (.interruptModel, nil)
    }
    return (.exitChat, nil)
  }

  // MARK: - Model turn end (auto-flush)

  /// Called by the host when the model transitions from busy → idle.
  ///
  /// If a message was queued while the model was busy, it is auto-flushed
  /// to the coordinator now.  Only fires when model is currently idle.
  mutating func handleModelTurnEnd() -> SubmitEffect {
    guard !modelBusy, let queued = queuedText else { return .none }
    queuedText = nil
    return .sendToGate(queued)
  }
}

// MARK: - Host-side effect application (testable)

/// Host-side mutable state affected by `SubmitEffect` application.
/// Pure value type — testable without any TUI infrastructure.
struct HostSubmitState: Equatable {
  var queuedTrayText: String? = nil

  /// Side effects the host must perform after applying the state transition.
  struct SideEffects: Equatable {
    var gateText: String? = nil
    /// Non-nil tag means the host must request a model interrupt + log with this tag.
    var interruptLogTag: String? = nil
    var needsDelayedRenderWake: Bool = false
    var shouldExit: Bool = false
  }

  /// Apply a `SubmitEffect` to host state, returning the side effects the
  /// host must execute (gate completion, interrupt, delayed wake, exit).
  ///
  /// This function is pure — all host-side state mutations are captured in
  /// `state` and all imperative actions are described in the returned
  /// `SideEffects`.  The host is responsible for executing those effects.
  static func apply(_ effect: SubmitEffect, to state: inout HostSubmitState) -> SideEffects {
    var fx = SideEffects()
    switch effect {
    case .sendToGate(let text):
      state.queuedTrayText = nil
      fx.gateText = text
      fx.needsDelayedRenderWake = true

    case .interruptAndSend(let text):
      state.queuedTrayText = nil
      fx.gateText = text
      fx.interruptLogTag = "interrupt-and-send"
      fx.needsDelayedRenderWake = true

    case .setQueued(let text):
      state.queuedTrayText = text

    case .clearQueued:
      state.queuedTrayText = nil

    case .interruptModel:
      fx.interruptLogTag = "requested-by-ctrl-c"

    case .exitChat:
      fx.shouldExit = true

    case .none:
      break
    }
    return fx
  }
}
