public enum SubmitEffect: Equatable, Sendable {

  case sendToGate(String)
  case popAndSendToGate

  case interruptAndSend(String)
  case popAndInterruptAndSend
  case recallQueuedToInput
  case enqueue(String)

  case interruptModel

  case exitChat

  case none
}

public enum SubmitCoordinator {

  public static func handleEnter(
    text: String,
    modelBusy: Bool,
    queueCount: Int,
    queuedLineOutstanding: Bool
  ) -> SubmitEffect {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

    if trimmed.isEmpty {
      guard queueCount > 0 else {
        return .none
      }
      if modelBusy {
        return .interruptModel
      }
      if queuedLineOutstanding {
        return .none
      }
      return .popAndSendToGate
    }

    if modelBusy {
      return .enqueue(text)
    }

    return .sendToGate(text)
  }

  public static func handleCtrlC(
    queueCount: Int,
    modelBusy: Bool
  ) -> SubmitEffect {
    if queueCount > 0 {
      return .recallQueuedToInput
    }
    if modelBusy {
      return .interruptModel
    }
    return .exitChat
  }
}
