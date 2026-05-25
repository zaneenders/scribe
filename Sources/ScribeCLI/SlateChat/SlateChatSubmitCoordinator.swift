
/// Effects the host must perform in response to a submit action.
/// Each case maps to exactly one host-side operation — no ambiguity.
enum SubmitEffect: Equatable, Sendable {
  /// Send text to the coordinator via `UserLineGate` (model is idle).
  case sendToGate(String)
  case popAndSendToGate
  /// Interrupt the model and send text to the gate.
  case interruptAndSend(String)
  case popAndInterruptAndSend
  case recallSteeringToInput
  case enqueueSteering(String)
  case enqueueFollowUp(String)
  /// Request an interrupt of the in-flight model turn.
  case interruptModel
  /// Stop the chat loop (Ctrl+C on idle, Ctrl+D, EOF).
  case exitChat
  /// No state change needed.
  case none
}

enum SubmitCoordinator {

  /// User pressed Enter with `text` in the input buffer.
  static func handleEnter(
    text: String,
    modelBusy: Bool,
    steeringQueueCount: Int,
    steeringLineOutstanding: Bool
  ) -> SubmitEffect {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

    if trimmed.isEmpty {
      guard steeringQueueCount > 0 else {
        return .none
      }
      if modelBusy {
        return .interruptModel
      }
      if steeringLineOutstanding {
        return .none
      }
      return .popAndSendToGate
    }

    if modelBusy {
      return .enqueueSteering(text)
    }

    return .sendToGate(text)
  }

  static func handleFollowUpSubmit(
    text: String,
    modelBusy: Bool
  ) -> SubmitEffect {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return .none }
    if modelBusy {
      return .enqueueFollowUp(text)
    }
    return .sendToGate(text)
  }

  /// Three-step ladder, evaluated in order:
  /// 1. Queued steering message present → recall oldest to input buffer.
  /// 2. Model is busy → request interrupt.
  /// 3. Model is idle, nothing queued → exit chat.
  static func handleCtrlC(
    steeringQueueCount: Int,
    modelBusy: Bool
  ) -> SubmitEffect {
    if steeringQueueCount > 0 {
      return .recallSteeringToInput
    }
    if modelBusy {
      return .interruptModel
    }
    return .exitChat
  }
}


struct HostSubmitSideEffects: Equatable {
  var gateText: String?
  var popSteeringToGate: Bool = false
  /// Non-nil tag means the host must request a model interrupt + log with this tag.
  var interruptLogTag: String?
  var needsDelayedRenderWake: Bool = false
  var shouldExit: Bool = false
  var enqueueSteering: String?
  var enqueueFollowUp: String?
  var recallSteeringToInput: Bool = false

  static func from(_ effect: SubmitEffect) -> HostSubmitSideEffects {
    var fx = HostSubmitSideEffects()
    switch effect {
    case .sendToGate(let text):
      fx.gateText = text
      fx.needsDelayedRenderWake = true

    case .popAndSendToGate:
      fx.popSteeringToGate = true
      fx.needsDelayedRenderWake = true

    case .interruptAndSend(let text):
      fx.gateText = text
      fx.interruptLogTag = "interrupt-and-send"
      fx.needsDelayedRenderWake = true

    case .popAndInterruptAndSend:
      fx.popSteeringToGate = true
      fx.interruptLogTag = "interrupt-and-send"
      fx.needsDelayedRenderWake = true

    case .recallSteeringToInput:
      fx.recallSteeringToInput = true

    case .enqueueSteering(let text):
      fx.enqueueSteering = text

    case .enqueueFollowUp(let text):
      fx.enqueueFollowUp = text

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
