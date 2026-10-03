import Foundation

public struct CodexAccessCredential: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible
{
  public let access: String
  public let accountId: String
  public let expires: Int64
  public var description: String { "CodexAccessCredential(<redacted>)" }
  public var debugDescription: String { description }

  public init(access: String, accountId: String, expires: Int64) {
    self.access = access
    self.accountId = accountId
    self.expires = expires
  }
  public init(_ credential: CodexCredential) {
    self.init(access: credential.access, accountId: credential.accountId, expires: credential.expires)
  }
}

public protocol CodexAccessCredentialProvider: Sendable {
  func credential(rejectingAccessToken: String?) async throws -> CodexAccessCredential
}

public struct CodexDefaultAccessProvider: CodexAccessCredentialProvider {
  public let baseDirectory: URL?
  public init(baseDirectory: URL? = nil) { self.baseDirectory = baseDirectory }

  public func credential(rejectingAccessToken: String? = nil) async throws -> CodexAccessCredential {
    CodexAccessCredential(
      try await CodexOAuth.getValidCredentials(
        baseDirectory: baseDirectory, rejectingAccessToken: rejectingAccessToken))
  }
}
