import Foundation
import SystemPackage

public enum EditOp: Sendable {

  case append([ScribeMessage])

  case fork(cutAt: Int, newSessionId: UUID)

  case forkSplice(
    startCut: Int,
    endCut: Int,
    replacement: [ScribeMessage],
    newSessionId: UUID
  )
}

public struct SessionParent: Sendable {
  public let sessionId: UUID
  public let forkPoint: Int

  public init(sessionId: UUID, forkPoint: Int) {
    self.sessionId = sessionId
    self.forkPoint = forkPoint
  }
}
