import Foundation
import Synchronization

public struct CodexAccessCredential: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
  public let access: String
  public let accountId: String
  public let expires: Int64
  public let lease: String
  public var description: String { "CodexAccessCredential(<redacted>)" }
  public var debugDescription: String { description }

  public init(access: String, accountId: String, expires: Int64, lease: String) {
    self.access = access
    self.accountId = accountId
    self.expires = expires
    self.lease = lease
  }
  public init(_ credential: CodexCredential) {
    self.init(access: credential.access, accountId: credential.accountId, expires: credential.expires, lease: "local")
  }
}

public protocol CodexAccessCredentialProvider: Sendable {
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
    case .serverOwned(let authority):
      try CodexAuthority.finishCommittedCleanup(baseDirectory: baseDirectory)
      return try await CodexServerProviders.credential(authority, rejecting: rejectingAccessToken)
    case .handoffPending: throw CodexAuthorityError.frozen
    case .recoveryRequired: throw CodexAuthorityError.recoveryRequired
    }
  }
}

public enum CodexServerProviders {
  private static let providers = Mutex<[CodexServerAuthorityKey: any CodexAccessCredentialProvider]>([:])
  public static func register(_ provider: any CodexAccessCredentialProvider, authority: CodexServerAuthority) {
    providers.withLock { $0[CodexServerAuthorityKey(authority)] = provider }
  }
  static func credential(_ authority: CodexServerAuthority, rejecting: String?) async throws -> CodexAccessCredential {
    let key = CodexServerAuthorityKey(authority)
    let provider = providers.withLock { $0[key] }
    if let provider { return try await provider.credential(rejectingAccessToken: rejecting) }
    let client = try CodexBrokerClient(origin: authority.origin, sshTunnel: authority.sshTunnel,
      bearer: { try CodexDeviceIdentity.bearer() })
    let created = CodexBrokerAccessProvider(client: client, authority: authority)
    let selected = providers.withLock { entries -> any CodexAccessCredentialProvider in
      if let existing = entries[key] { return existing }
      entries[key] = created
      return created
    }
    return try await selected.credential(rejectingAccessToken: rejecting)
  }
}

private struct CodexServerAuthorityKey: Hashable {
  let origin: String
  let connectionID: UUID
  init(_ authority: CodexServerAuthority) { origin = authority.origin; connectionID = authority.connectionID }
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
