import Foundation

/// JSON body from `scribe agent` (stdout).
public struct ScribeAgentResponse: Codable, Sendable, Equatable {
  public var ok: Bool
  public var assistant: String?
  public var error: String?

  public init(ok: Bool, assistant: String? = nil, error: String? = nil) {
    self.ok = ok
    self.assistant = assistant
    self.error = error
  }

  public static func success(assistant: String) -> Self {
    .init(ok: true, assistant: assistant, error: nil)
  }

  public static func failure(_ message: String) -> Self {
    .init(ok: false, assistant: nil, error: message)
  }
}
