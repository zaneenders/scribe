import Foundation
import Testing

@testable import ScribeCore

@Suite
struct CodexCredentialsTests {

  // MARK: - File permissions

  @Test("write sets file permissions to 0o600 (owner-only)")
  func writeSetsOwnerOnlyFilePermissions() throws {
    let tmpDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("scribe-cred-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    // Create directory first
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    let fileURL = tmpDir.appendingPathComponent("test-credentials.json")

    // Write a credential directly to the temp path
    let credential = CodexCredential(
      access: "test-access-token",
      refresh: "test-refresh-token",
      expires: Int64(Date().timeIntervalSince1970 * 1000) + 3_600_000,
      accountId: "test-account"
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(credential)
    try data.write(to: fileURL, options: .atomic)

    // Now apply the secure permissions
    try CodexCredentialStore.setSecureFilePermissions(at: fileURL)

    // Read back permissions
    let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    let mode = try #require(attrs[.posixPermissions] as? NSNumber)

    // Check owner r/w and nothing else
    #expect(mode.intValue == 0o600, "Expected 0o600 but got \(String(mode.intValue, radix: 8))")
  }

  @Test("write rejects group/other access bits")
  func writeRejectsGroupAndOtherAccess() throws {
    let tmpDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("scribe-cred-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    let fileURL = tmpDir.appendingPathComponent("test-credentials.json")

    // Create a credential
    let credential = CodexCredential(
      access: "access",
      refresh: "refresh",
      expires: 9_999_999_999_999,
      accountId: "acct"
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(credential)
    try data.write(to: fileURL, options: .atomic)

    // Set secure permissions
    try CodexCredentialStore.setSecureFilePermissions(at: fileURL)

    let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    let mode = try #require(attrs[.posixPermissions] as? NSNumber)

    // No group or other bits should be set
    let groupMask = 0o070
    let otherMask = 0o007
    #expect((mode.intValue & groupMask) == 0, "Group bits set: \(String(mode.intValue, radix: 8))")
    #expect((mode.intValue & otherMask) == 0, "Other bits set: \(String(mode.intValue, radix: 8))")
  }

  @Test("ensureSecureDirectory creates directory with 0o700")
  func ensureSecureDirectorySetsOwnerOnly() throws {
    let tmpDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("scribe-dir-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let subDir = tmpDir.appendingPathComponent("secure-subdir", isDirectory: true)

    // Call the internal helper
    CodexCredentialStore.ensureSecureDirectory(at: subDir)

    // Verify it exists
    var isDir: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: subDir.path, isDirectory: &isDir))
    #expect(isDir.boolValue)

    // Check permissions
    let attrs = try FileManager.default.attributesOfItem(atPath: subDir.path)
    let mode = try #require(attrs[.posixPermissions] as? NSNumber)

    #expect(mode.intValue == 0o700, "Expected 0o700 but got \(String(mode.intValue, radix: 8))")
  }

  @Test("ensureSecureDirectory tightens overly permissive existing directory")
  func ensureSecureDirectoryTightensExistingPermissions() throws {
    let tmpDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("scribe-dir-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    // Create a directory with wide permissions first (0o755)
    try FileManager.default.createDirectory(
      at: tmpDir,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: NSNumber(value: 0o755)]
    )

    // Now call ensureSecureDirectory — it should tighten to 0o700
    CodexCredentialStore.ensureSecureDirectory(at: tmpDir)

    let attrs = try FileManager.default.attributesOfItem(atPath: tmpDir.path)
    let mode = try #require(attrs[.posixPermissions] as? NSNumber)

    #expect(mode.intValue == 0o700, "Expected 0o700 after tightening but got \(String(mode.intValue, radix: 8))")
  }

  // MARK: - Credential model

  @Test("credential round-trips through JSON")
  func credentialRoundTrip() throws {
    let original = CodexCredential(
      access: "acc",
      refresh: "ref",
      expires: 1_700_000_000_000,
      accountId: "id-123"
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(original)
    let decoded = try JSONDecoder().decode(CodexCredential.self, from: data)

    #expect(decoded.type == "oauth")
    #expect(decoded.access == "acc")
    #expect(decoded.refresh == "ref")
    #expect(decoded.expires == 1_700_000_000_000)
    #expect(decoded.accountId == "id-123")
  }

  @Test("isExpired returns true for expired token")
  func isExpired() {
    let past = CodexCredential(
      access: "a", refresh: "r",
      expires: Int64(Date().timeIntervalSince1970 * 1000) - 60_001,
      accountId: "id"
    )
    #expect(past.isExpired)
  }

  @Test("isExpired returns false for valid token")
  func isNotExpired() {
    let future = CodexCredential(
      access: "a", refresh: "r",
      expires: Int64(Date().timeIntervalSince1970 * 1000) + 3_600_000,
      accountId: "id"
    )
    #expect(!future.isExpired)
  }
}
