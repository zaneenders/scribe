import Foundation

/// JSON body for `scribe agent` (stdin). Designed for nested or remote agents calling this process.
public struct ScribeAgentRequest: Codable, Sendable, Equatable {
  public var message: String

  public init(message: String) {
    self.message = message
  }
}
