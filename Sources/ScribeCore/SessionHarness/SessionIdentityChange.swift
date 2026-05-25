import Foundation
import SystemPackage

/// Emitted when ``SessionHarness/applyEdit(_:)`` swaps session identity
/// (``EditOp/fork`` or ``EditOp/forkSplice``).
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
