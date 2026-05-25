import Foundation
import SystemPackage

public struct SessionIdentityChange: Sendable {
  public let previousSessionId: UUID
  public let newSessionId: UUID
  public let newDirectory: FilePath

  public init(previousSessionId: UUID, newSessionId: UUID, newDirectory: FilePath) {
    self.previousSessionId = previousSessionId
    self.newSessionId = newSessionId
    self.newDirectory = newDirectory
  }
}
