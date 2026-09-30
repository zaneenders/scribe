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

  @Test func freezeWaitsForRefreshAndBlocksAllStoresAfterRestart() async throws {
    let directory = temporaryStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    try CodexCredentialStore.write(credential("old", expired: true), baseDirectory: directory)
    let started = AsyncStream<Void>.makeStream()
    let release = AsyncStream<Void>.makeStream()
    let manager = CodexCredentialManager { _, _ in
      started.continuation.yield(())
      for await _ in release.stream { break }
      return credential("rotated")
    }
    let refreshing = Task { try await manager.credentials(baseDirectory: directory) }
    for await _ in started.stream { break }
    #expect(throws: CodexAuthorityError.self) {
      try CodexCredentialStore.write(credential("other"), baseDirectory: directory)
    }
    let freezing = Task {
      try await CodexAuthority.freeze(origin: "https://trusted.example", accountID: "account",
        expectedGeneration: 0, baseDirectory: directory)
    }
    release.continuation.yield(())
    _ = try await refreshing.value
    let pending = try await freezing.value
    #expect(try CodexAuthority.export(pending, baseDirectory: directory).refresh == "refresh-rotated")
    #expect(try CodexAuthority.state(baseDirectory: directory) == .handoffPending(pending))
    await #expect(throws: CodexAuthorityError.self) {
      _ = try await CodexCredentialManager().credentials(baseDirectory: directory)
    }
    let receipt = CodexConnectionReceipt(handoffID: pending.id, connectionID: UUID(), accountID: "account", generation: 1)
    try CodexAuthority.commit(pending, receipt: receipt, baseDirectory: directory)
    try CodexAuthority.commit(pending, receipt: receipt, baseDirectory: directory)
    #expect(!FileManager.default.fileExists(atPath: CodexCredentialStore.credentialsPath(baseDirectory: directory).path))
    let authority: CodexServerAuthority
    guard case .serverOwned(let committed) = try CodexAuthority.state(baseDirectory: directory) else {
      Issue.record("Missing committed authority"); return
    }
    authority = committed
    CodexServerProviders.register(OfflineProvider(), authority: authority)
    await #expect(throws: CodexAuthorityError.self) {
      _ = try await CodexDefaultAccessProvider(baseDirectory: directory).credential()
    }
    #expect(throws: CodexAuthorityError.self) { try CodexCredentialStore.write(credential("new"), baseDirectory: directory) }
  }

  @Test func restartCompletesDeletionAfterCommittedAuthorityWasPersisted() async throws {
    let directory = temporaryStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    try CodexCredentialStore.write(credential("old"), baseDirectory: directory)
    let authority = CodexServerAuthority(origin: "https://trusted.example", sshTunnel: false,
      connectionID: UUID(), accountID: "account", generation: 1)
    // Crash point between the durable ownership fence and local credential deletion.
    try CodexSecureFile.write(CodexAuthorityState.serverOwned(authority), to: CodexAuthority.path(directory))
    CodexServerProviders.register(OfflineProvider(), authority: authority)
    await #expect(throws: CodexAuthorityError.self) {
      _ = try await CodexDefaultAccessProvider(baseDirectory: directory).credential()
    }
    #expect(!FileManager.default.fileExists(atPath: CodexCredentialStore.credentialsPath(baseDirectory: directory).path))
    #expect(try CodexAuthority.state(baseDirectory: directory) == .serverOwned(authority))
  }

  @Test func ambiguousRefreshStaysFencedAcrossRestart() async throws {
    let directory = temporaryStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    try CodexCredentialStore.write(credential("old", expired: true), baseDirectory: directory)
    let manager = CodexCredentialManager { _, _ in throw CodexAuthorityError.unavailable }
    await #expect(throws: CodexAuthorityError.self) { _ = try await manager.credentials(baseDirectory: directory) }
    #expect(try CodexAuthority.state(baseDirectory: directory) == .recoveryRequired)
    let restarted = CodexCredentialManager { _, _ in Issue.record("Must not replay refresh"); return credential("bad") }
    await #expect(throws: CodexAuthorityError.self) { _ = try await restarted.credentials(baseDirectory: directory) }
  }

  @Test func pendingHandoffCannotChangeOriginAccountOrGeneration() async throws {
    let directory = temporaryStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    try CodexCredentialStore.write(credential("old"), baseDirectory: directory)
    let pending = try await CodexAuthority.freeze(origin: "https://trusted.example", accountID: "account", expectedGeneration: 0, baseDirectory: directory)
    #expect(try await CodexAuthority.freeze(origin: "https://trusted.example", accountID: "account", expectedGeneration: 0, baseDirectory: directory) == pending)
    await #expect(throws: CodexAuthorityError.self) {
      _ = try await CodexAuthority.freeze(origin: "https://evil.example", accountID: "account", expectedGeneration: 0, baseDirectory: directory)
    }
    #expect(throws: CodexAuthorityError.self) {
      try CodexAuthority.commit(pending, receipt: .init(handoffID: pending.id, connectionID: UUID(), accountID: "other", generation: 1), baseDirectory: directory)
    }
    #expect(throws: CodexAuthorityError.self) { try CodexCredentialStore.delete(baseDirectory: directory) }
    #expect(try CodexAuthority.state(baseDirectory: directory) == .handoffPending(pending))
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

private struct OfflineProvider: CodexAccessCredentialProvider {
  func credential(rejectingAccessToken: String?) async throws -> CodexAccessCredential { throw CodexAuthorityError.unavailable }
}
