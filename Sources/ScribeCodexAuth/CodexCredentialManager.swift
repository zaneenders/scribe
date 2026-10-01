import Foundation

/// Shares refreshes across sessions because OAuth refresh tokens can rotate after use.
actor CodexCredentialManager {
  static let shared = CodexCredentialManager()

  private var refreshes: [URL: Task<CodexCredential, Error>] = [:]
  private let refresh: @Sendable (CodexCredential, URL) async throws -> CodexCredential

  init(
    refresh: @escaping @Sendable (CodexCredential, URL) async throws -> CodexCredential = {
      try await CodexOAuth.refresh($0, baseDirectory: $1)
    }
  ) {
    self.refresh = refresh
  }

  func credentials(
    baseDirectory: URL,
    rejectingAccessToken: String? = nil
  ) async throws -> CodexCredential {
    let directory = baseDirectory.standardizedFileURL
    if let pending = refreshes[directory] {
      return try await pending.value
    }
    guard let credential = try CodexCredentialStore.read(baseDirectory: directory) else {
      throw CodexOAuthError.noCredentials
    }
    // Another session or a browser login may already have replaced the rejected token.
    guard credential.isExpired || credential.access == rejectingAccessToken else {
      return credential
    }

    let task = Task { [refresh] in
      do {
        return try await refresh(credential, directory)
      } catch let CodexOAuthError.tokenExchangeFailed(status, body) {
        if status == 401 || status == 403 || (status == 400 && body.contains("invalid_grant")) {
          throw CodexOAuthError.loginRequired
        }
        throw CodexOAuthError.tokenExchangeFailed(status: status, body: body)
      }
    }
    refreshes[directory] = task
    defer { refreshes[directory] = nil }
    return try await task.value
  }
}
