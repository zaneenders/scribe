
/// Effects the host must perform in response to a submit action.
/// Each case maps to exactly one host-side operation — no ambiguity.
enum SubmitEffect: Equatable, Sendable {
  /// Send text to the coordinator via `UserLineGate` (model is idle).
  case sendToGate(String)
  /// Interrupt the model AND send text to the gate (empty Enter with queued message).
  case interruptAndSend(String)
  /// Park text in the queued tray (model is busy).  Associated value is the
  /// updated array so the host can update its rendering state.
  case setQueued([String])
  /// Remove first queued item (Ctrl+C recall).  Associated value is the
  /// remaining array after the pop.
  case clearQueued([String])
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
  /// Queued submissions (FIFO) parked while the model is busy.
  private(set) var queuedTexts: [String] = []


  /// Call before `handleEnter` / `handleCtrlC` so the coordinator knows
  /// whether the model is currently processing a turn.
  mutating func setModelBusy(_ busy: Bool) {
    modelBusy = busy
  }


  /// User pressed Enter with `text` in the input buffer.
  mutating func handleEnter(text: String) -> SubmitEffect {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

    if trimmed.isEmpty {
      // Empty buffer + queued tray → interrupt-and-send oldest.
      guard !queuedTexts.isEmpty else {
        return .none  // Empty buffer, nothing queued → no-op.
      }
      let queued = queuedTexts.removeFirst()
      if modelBusy {
        return .interruptAndSend(queued)
      }
      return .sendToGate(queued)
    }

    if modelBusy {
      queuedTexts.append(text)
      return .setQueued(queuedTexts)
    }

    return .sendToGate(text)
  }


  /// Three-step ladder, evaluated in order:
  /// 1. Queued message present → recall oldest to input buffer.
  /// 2. Model is busy → request interrupt.
  /// 3. Model is idle, nothing queued → exit chat.
  mutating func handleCtrlC() -> (effect: SubmitEffect, recallText: String?) {
    if !queuedTexts.isEmpty {
      let queued = queuedTexts.removeFirst()
      return (.clearQueued(queuedTexts), queued)
    }
    if modelBusy {
      return (.interruptModel, nil)
    }
    return (.exitChat, nil)
  }


  /// Called by the host when the model transitions from busy → idle.
  ///
  /// If messages were queued while the model was busy, they are all
  /// auto-flushed to the coordinator now.  Returns an array of texts
  /// to send (oldest first), or an empty array when nothing is queued.
  ///
  /// TODO: make drain strategy pluggable (all-at-once vs one-per-turn).
  /// A hook/plugin could choose to drain only the oldest message here and
  /// leave the rest for subsequent turns, which would let the user
  /// interrupt or recall individual queued messages between auto-flushes
  /// instead of having them all pushed out in one burst.
  mutating func handleModelTurnEnd() -> [String] {
    guard !modelBusy, !queuedTexts.isEmpty else { return [] }
    let drained = queuedTexts
    queuedTexts = []
    return drained
  }
}


/// Host-side mutable state affected by `SubmitEffect` application.
/// Pure value type — testable without any TUI infrastructure.
struct HostSubmitState: Equatable {
  var queuedTrayTexts: [String] = []

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
      fx.gateText = text
      fx.needsDelayedRenderWake = true

    case .interruptAndSend(let text):
      fx.gateText = text
      fx.interruptLogTag = "interrupt-and-send"
      fx.needsDelayedRenderWake = true

    case .setQueued(let texts):
      state.queuedTrayTexts = texts

    case .clearQueued(let texts):
      state.queuedTrayTexts = texts

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
