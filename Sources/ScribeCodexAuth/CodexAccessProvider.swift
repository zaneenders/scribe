import Foundation

public struct CodexAccessCredential: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
  public let access: String
  public let accountId: String
  /// Access-token expiration in milliseconds since the Unix epoch.
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

/// Supplies access-only credentials; storage, refresh, and broker networking belong to the provider.
public protocol CodexAccessCredentialProvider: Sendable {
  /// Return a valid credential. When a token is rejected (HTTP 401), replace it or throw.
  /// Do not fall back to a different account or local OAuth after broker failure.
  func credential(rejectingAccessToken: String?) async throws -> CodexAccessCredential
}

public struct CodexDefaultAccessProvider: CodexAccessCredentialProvider {
  public let baseDirectory: URL?
  public init(baseDirectory: URL? = nil) { self.baseDirectory = baseDirectory }

  public func credential(rejectingAccessToken: String? = nil) async throws -> CodexAccessCredential {
    switch try CodexAuthority.state(baseDirectory: baseDirectory) {
    case .local:
      return CodexAccessCredential(try await CodexOAuth.getValidCredentials(
        baseDirectory: baseDirectory, rejectingAccessToken: rejectingAccessToken))
    case .serverOwned:
      try CodexAuthority.finishCommittedCleanup(baseDirectory: baseDirectory)
      throw CodexAuthorityError.frozen
    case .handoffPending: throw CodexAuthorityError.frozen
    case .recoveryRequired: throw CodexAuthorityError.recoveryRequired
    }
  }
}

public actor CodexAccountBoundProvider: CodexAccessCredentialProvider {
  private let provider: any CodexAccessCredentialProvider
  private var accountID: String?
  public init(_ provider: any CodexAccessCredentialProvider) { self.provider = provider }
  public func credential(rejectingAccessToken: String?) async throws -> CodexAccessCredential {
    let value = try await provider.credential(rejectingAccessToken: rejectingAccessToken)
    guard accountID == nil || accountID == value.accountId else { throw CodexAuthorityError.conflict }
    accountID = value.accountId
    return value
  }
}
