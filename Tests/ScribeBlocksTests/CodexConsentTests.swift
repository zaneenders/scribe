import Foundation
import ScribeCodexAuth
import Synchronization
import Testing
@testable import ScribeBlocks

@MainActor struct CodexConsentTests {
  @Test func editingOriginOrTransportInvalidatesConsentWithoutSendingSecrets() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let calls = Mutex(0)
    let settings = CodexConnectionSettings(baseDirectory: directory, bearer: {
      calls.withLock { $0 += 1 }
      throw CodexAuthorityError.denied
    })
    settings.serverOrigin = "https://trusted.example"
    #expect(settings.consent == nil)
    settings.requestConsent()
    #expect(settings.consent == "https://trusted.example")
    #expect(settings.consentMessage?.contains("trusted.example") == true)
    settings.serverOrigin = "https://other.example"
    settings.confirm()
    #expect(!settings.busy)
    #expect(calls.withLock { $0 } == 0)
    settings.requestConsent()
    settings.sshTunnel = true
    settings.confirm()
    #expect(!settings.busy)
    #expect(calls.withLock { $0 } == 0)
    #expect(try CodexAuthority.state(baseDirectory: directory) == .local)
  }

  @Test func consentDisplaysExactAccountAndFreezesOnlyAfterConfirmation() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try CodexCredentialStore.write(.init(access: "access-secret", refresh: "refresh-secret",
      expires: Int64(Date().timeIntervalSince1970 * 1000) + 3_600_000, accountId: "expected-account"), baseDirectory: directory)
    let settings = CodexConnectionSettings(baseDirectory: directory, bearer: { throw CodexAuthorityError.denied })
    settings.requestConsent(origin: "https://trusted.example")
    #expect(settings.consentMessage?.contains("expected-account") == true)
    #expect(settings.consentMessage?.contains("secret") == false)
    #expect(try CodexAuthority.state(baseDirectory: directory) == .local)
    settings.cancelConsent()
    settings.confirm()
    #expect(!settings.busy)
    #expect(try CodexCredentialStore.read(baseDirectory: directory)?.refresh == "refresh-secret")
  }
}
