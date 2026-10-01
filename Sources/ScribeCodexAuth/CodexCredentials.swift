import Foundation

public struct CodexCredential: Sendable, Codable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
  public var description: String { "CodexCredential(<redacted>)" }
  public var debugDescription: String { description }
  public let type: String
  public let access: String
  public let refresh: String
  public let expires: Int64
  public let accountId: String

  public init(access: String, refresh: String, expires: Int64, accountId: String) {
    self.type = "oauth"
    self.access = access
    self.refresh = refresh
    self.expires = expires
    self.accountId = accountId
  }

  public var isExpired: Bool {
    let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
    return expires <= nowMs + 60_000
  }
}

public enum CodexCredentialStore {
  private static let credentialsFileName = "codex-credentials.json"

  public static func resolveBaseDirectory() -> URL {
    if let raw = ProcessInfo.processInfo.environment["SCRIBE_HOME"] {
      let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty {
        return URL(
          fileURLWithPath: NSString(string: trimmed).expandingTildeInPath,
          isDirectory: true
        ).standardizedFileURL
      }
    }
    return URL(
      fileURLWithPath: NSString(string: "~/.scribe").expandingTildeInPath,
      isDirectory: true
    ).standardizedFileURL
  }

  public static func credentialsPath(baseDirectory: URL? = nil) -> URL {
    let base = baseDirectory ?? resolveBaseDirectory()
    ensureSecureDirectory(at: base)
    return base.appendingPathComponent(credentialsFileName)
  }

  public static func read(baseDirectory: URL? = nil) throws -> CodexCredential? {
    let directory = baseDirectory ?? resolveBaseDirectory()
    let lock = try CodexStoreLock(directory: directory)
    defer { withExtendedLifetime(lock) {} }
    try CodexCredentialFence.requireLocal(directory)
    return try readRaw(baseDirectory: directory)
  }

  public static func readRaw(baseDirectory: URL) throws -> CodexCredential? {
    let path = credentialsPath(baseDirectory: baseDirectory)
    guard FileManager.default.fileExists(atPath: path.path) else { return nil }

    tightenFilePermissions(at: path)

    do {
      let data = try Data(contentsOf: path)
      return try JSONDecoder().decode(CodexCredential.self, from: data)
    } catch { throw CodexAuthorityError.unavailable }
  }

  public static func write(_ credential: CodexCredential, baseDirectory: URL? = nil) throws {
    let directory = baseDirectory ?? resolveBaseDirectory()
    let lock = try CodexStoreLock(directory: directory)
    defer { withExtendedLifetime(lock) {} }
    try CodexCredentialFence.requireLocal(directory)
    try writeUnlocked(credential, baseDirectory: directory)
  }

  static func replace(
    _ original: CodexCredential,
    with refreshed: CodexCredential,
    baseDirectory: URL? = nil
  ) throws -> CodexCredential {
    let directory = baseDirectory ?? resolveBaseDirectory()
    let lock = try CodexStoreLock(directory: directory)
    defer { withExtendedLifetime(lock) {} }
    try CodexCredentialFence.requireLocal(directory)
    guard let current = try readRaw(baseDirectory: directory) else { throw CodexOAuthError.noCredentials }
    guard current == original else { return current }
    try writeUnlocked(refreshed, baseDirectory: directory)
    return refreshed
  }

  static func writeUnlocked(_ credential: CodexCredential, baseDirectory: URL) throws {
    try CodexSecureFile.write(credential, to: credentialsPath(baseDirectory: baseDirectory))
  }

  public static func delete(baseDirectory: URL? = nil) throws {
    let directory = baseDirectory ?? resolveBaseDirectory()
    let lock = try CodexStoreLock(directory: directory)
    defer { withExtendedLifetime(lock) {} }
    try CodexCredentialFence.requireLocal(directory)
    try deleteRaw(baseDirectory: directory)
    try CodexSecureFile.sync(directory)
  }

  public static func deleteRaw(baseDirectory: URL) throws {
    let path = credentialsPath(baseDirectory: baseDirectory)
    if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
  }

  static func ensureSecureDirectory(at url: URL) {
    let fm = FileManager.default
    let attrs: [FileAttributeKey: Any] = [.posixPermissions: NSNumber(value: 0o700)]

    if !fm.fileExists(atPath: url.path) {
      try? fm.createDirectory(
        at: url,
        withIntermediateDirectories: true,
        attributes: attrs
      )
    } else {
      tightenDirectoryPermissions(at: url)
    }
  }

  static func setSecureFilePermissions(at url: URL) throws {
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: 0o600)],
      ofItemAtPath: url.path
    )
  }

  private static func tightenFilePermissions(at url: URL) {
    guard let current = try? FileManager.default.attributesOfItem(atPath: url.path),
      let mode = current[.posixPermissions] as? NSNumber
    else { return }

    let mask = 0o077
    if mode.intValue & mask != 0 {
      try? setSecureFilePermissions(at: url)
    }
  }

  private static func tightenDirectoryPermissions(at url: URL) {
    guard let current = try? FileManager.default.attributesOfItem(atPath: url.path),
      let mode = current[.posixPermissions] as? NSNumber
    else { return }

    let mask = 0o077
    if mode.intValue & mask != 0 {
      try? FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o700)],
        ofItemAtPath: url.path
      )
    }
  }
}
