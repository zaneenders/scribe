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
