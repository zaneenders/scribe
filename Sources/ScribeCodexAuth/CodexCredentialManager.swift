import Foundation

actor CodexCredentialManager {
  static let shared = CodexCredentialManager()
  private let refresh: @Sendable (CodexCredential, URL) async throws -> CodexCredential

  init(refresh: @escaping @Sendable (CodexCredential, URL) async throws -> CodexCredential = { credential, _ in
    try await CodexOAuth.rotateOwnedCredential(credential)
  }) {
    self.refresh = refresh
  }

  func credentials(baseDirectory: URL, rejectingAccessToken: String? = nil) async throws -> CodexCredential {
    let directory = baseDirectory.standardizedFileURL
    let lock = try await CodexStoreLock.acquire(directory: directory)
    defer { withExtendedLifetime(lock) {} }
    try CodexAuthority.requireLocal(directory)
    guard let credential = try CodexCredentialStore.readRaw(baseDirectory: directory) else {
      throw CodexOAuthError.noCredentials
    }
    guard credential.isExpired || credential.access == rejectingAccessToken else { return credential }
    // A crash or ambiguous network failure must not replay a rotating refresh token.
    try CodexSecureFile.write(CodexAuthorityState.recoveryRequired, to: CodexAuthority.path(directory))
    do {
      let updated = try await refresh(credential, directory)
      guard updated.accountId == credential.accountId else { throw CodexAuthorityError.conflict }
      try CodexCredentialStore.writeUnlocked(updated, baseDirectory: directory)
      try CodexSecureFile.write(CodexAuthorityState.local, to: CodexAuthority.path(directory))
      return updated
    } catch {
      throw CodexAuthorityError.recoveryRequired
    }
  }
}
