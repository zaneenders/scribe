import Foundation
import Testing
@testable import ScribeCodexAuth

struct CodexCredentialManagerTests {
  @Test(arguments: [false, true])
  func coordinatesIndependentManagers(rejected: Bool) async throws {
    let directory = temporaryStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let original = credential("original", expired: !rejected)
    try CodexCredentialStore.write(original, baseDirectory: directory)
    let probe = RefreshProbe()
    let refresh: @Sendable (CodexCredential, URL) async throws -> CodexCredential = { _, _ in
      await probe.record()
      try await Task.sleep(for: .milliseconds(40))
      return credential("updated")
    }
    let managers = [CodexCredentialManager(refresh: refresh), CodexCredentialManager(refresh: refresh)]
    try await withThrowingTaskGroup(of: String.self) { group in
      for index in 0..<20 {
        group.addTask {
          try await managers[index % 2].credentials(baseDirectory: directory,
            rejectingAccessToken: rejected ? "original" : nil).access
        }
      }
      for try await result in group { #expect(result == "updated") }
    }
    #expect(await probe.count == 1)
    #expect(try CodexCredentialStore.read(baseDirectory: directory)?.refresh == "refresh-updated")
  }

  @Test func ambiguousRefreshStaysFencedAcrossRestart() async throws {
    let directory = temporaryStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    try CodexCredentialStore.write(credential("old", expired: true), baseDirectory: directory)
    let manager = CodexCredentialManager { _, _ in throw CodexAuthorityError.unavailable }
    await #expect(throws: CodexAuthorityError.self) { _ = try await manager.credentials(baseDirectory: directory) }
    #expect(try CodexCredentialFence.state(baseDirectory: directory) == .recoveryRequired)
    let restarted = CodexCredentialManager { _, _ in Issue.record("Must not replay refresh"); return credential("bad") }
    await #expect(throws: CodexAuthorityError.self) { _ = try await restarted.credentials(baseDirectory: directory) }
  }
}

private func temporaryStore() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
private func credential(_ token: String, expired: Bool = false) -> CodexCredential {
  .init(access: token, refresh: "refresh-\(token)", expires: expired ? 0 : Int64(Date().timeIntervalSince1970 * 1000) + 3_600_000, accountId: "account")
}
private actor RefreshProbe {
  private(set) var count = 0
  func record() { count += 1 }
}
