

enum SubmitEffect: Equatable, Sendable {

  case sendToGate(String)
  case popAndSendToGate

  case interruptAndSend(String)
  case popAndInterruptAndSend
  case recallSteeringToInput
  case enqueueSteering(String)
  case enqueueFollowUp(String)

  case interruptModel

  case exitChat

  case none
}

enum SubmitCoordinator {

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
