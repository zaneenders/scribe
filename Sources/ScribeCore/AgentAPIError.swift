import Foundation

public struct AgentAPIError: Error, LocalizedError {
  public var errorDescription: String?

  public init(description: String) {
    self.errorDescription = description
  }
}
