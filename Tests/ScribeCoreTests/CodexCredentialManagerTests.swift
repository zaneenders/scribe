import Foundation
import Testing

@testable import ScribeCodexAuth

struct CodexCredentialManagerTests {
  @Test("concurrent sessions share one refresh for an expired or rejected token", arguments: [false, true])
  func sharesRefresh(rejected: Bool) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let original = credential("original", expired: !rejected)
    let updated = credential("updated")
    try CodexCredentialStore.write(original, baseDirectory: directory)
    let probe = RefreshProbe()
    let manager = CodexCredentialManager { _, directory in
      await probe.record()
      try await Task.sleep(for: .milliseconds(50))
      try CodexCredentialStore.write(updated, baseDirectory: directory)
      return updated
    }

    let results = try await withThrowingTaskGroup(of: String.self) { group in
      for _ in 0..<20 {
        group.addTask {
          try await manager.credentials(
            baseDirectory: directory, rejectingAccessToken: rejected ? "original" : nil).access
        }
      }
      var results: [String] = []
      for try await result in group { results.append(result) }
      return results
    }
    #expect(results == Array(repeating: "updated", count: 20))
    #expect(await probe.count == 1)
    #expect(try CodexCredentialStore.read(baseDirectory: directory)?.refresh == updated.refresh)
  }

  @Test("a stale 401 uses a newer saved browser login without refreshing it")
  func usesReplacementLogin() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try CodexCredentialStore.write(credential("browser-login"), baseDirectory: directory)
    let manager = CodexCredentialManager { _, _ in
      Issue.record("Replacement login should not be refreshed")
      throw CodexOAuthError.loginRequired
    }
    let result = try await manager.credentials(baseDirectory: directory, rejectingAccessToken: "old-token")
    #expect(result.access == "browser-login")
  }

  @Test("revoked refresh tokens require sign-in while server failures retain their cause", arguments: [401, 503])
  func reportsRefreshFailure(status: Int) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try CodexCredentialStore.write(credential("original", expired: true), baseDirectory: directory)
    let manager = CodexCredentialManager { _, _ in
      throw CodexOAuthError.tokenExchangeFailed(status: status, body: "refresh failed")
    }
    do {
      _ = try await manager.credentials(baseDirectory: directory)
      Issue.record("Expected a refresh failure")
    } catch let error as CodexOAuthError {
      switch (status, error) {
      case (401, .loginRequired), (503, .tokenExchangeFailed(status: 503, body: _)): break
      default: Issue.record("Unexpected refresh error: \(error)")
      }
    }
    #expect(try CodexCredentialStore.read(baseDirectory: directory)?.access == "original")
  }

  private func credential(_ access: String, expired: Bool = false) -> CodexCredential {
    CodexCredential(
      access: access, refresh: "refresh-\(access)", expires: expired ? 0 : 9_999_999_999_999,
      accountId: "account")
  }
}

private actor RefreshProbe {
  private(set) var count = 0
  func record() { count += 1 }
}
