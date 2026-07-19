import Foundation

// MARK: - Credential Model

/// An OAuth credential for the ChatGPT subscription backend.
public struct CodexCredential: Sendable, Codable {
  /// Always "oauth" for Codex credentials.
  public let type: String
  /// The OAuth access token (Bearer).
  public let access: String
  /// The OAuth refresh token.
  public let refresh: String
  /// Unix timestamp in milliseconds when `access` expires.
  public let expires: Int64
  /// The ChatGPT account ID (from the JWT).
  public let accountId: String

  public init(access: String, refresh: String, expires: Int64, accountId: String) {
    self.type = "oauth"
    self.access = access
    self.refresh = refresh
    self.expires = expires
    self.accountId = accountId
  }

  /// True if the access token has expired or expires within the next 60 seconds.
  public var isExpired: Bool {
    let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
    return expires <= nowMs + 60_000
  }
}

// MARK: - Credential Storage

/// Persists Codex credentials to a JSON file under the Scribe data directory.
///
/// The data directory is resolved from the `SCRIBE_HOME` environment variable
/// (falling back to `~/.scribe/`) unless an explicit `baseDirectory` is supplied.
///
/// The file and its containing directory are locked down to owner-only
/// access (0o600 / 0o700) so a long-lived OAuth refresh token cannot
/// be read by other local users regardless of the process umask.
public enum CodexCredentialStore {
  private static let credentialsFileName = "codex-credentials.json"

  // MARK: - Base directory resolution

  /// Resolves the Scribe data home directory.
  ///
  /// When `SCRIBE_HOME` is set it is used verbatim (after tilde expansion);
  /// otherwise the default `~/.scribe/` is used.
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

  // MARK: - Paths

  /// Path to the credentials file.
  ///
  /// - Parameter baseDirectory: Explicit data-home override.  Pass `nil`
  ///   (the default) to use the `SCRIBE_HOME`-aware default.
  public static func credentialsPath(baseDirectory: URL? = nil) -> URL {
    let base = baseDirectory ?? resolveBaseDirectory()
    ensureSecureDirectory(at: base)
    return base.appendingPathComponent(credentialsFileName)
  }

  // MARK: - Read / Write / Delete

  /// Read stored credentials, if any.
  ///
  /// If the file exists but has overly permissive POSIX permissions they
  /// are tightened to 0o600 before the read proceeds.
  ///
  /// - Parameter baseDirectory: Explicit data-home override.
  public static func read(baseDirectory: URL? = nil) throws -> CodexCredential? {
    let path = credentialsPath(baseDirectory: baseDirectory)
    guard FileManager.default.fileExists(atPath: path.path) else { return nil }

    // Tighten permissions if the file was created by an older version.
    tightenFilePermissions(at: path)

    let data = try Data(contentsOf: path)
    return try JSONDecoder().decode(CodexCredential.self, from: data)
  }

  /// Write credentials to disk with owner-only (0o600) permissions.
  ///
  /// The file is written atomically and then the POSIX mode is set
  /// explicitly so the process umask cannot accidentally broaden access.
  ///
  /// - Parameter baseDirectory: Explicit data-home override.
  public static func write(_ credential: CodexCredential, baseDirectory: URL? = nil) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(credential)
    let path = credentialsPath(baseDirectory: baseDirectory)
    try data.write(to: path, options: .atomic)
    try setSecureFilePermissions(at: path)
  }

  /// Remove stored credentials (logout).
  ///
  /// - Parameter baseDirectory: Explicit data-home override.
  public static func delete(baseDirectory: URL? = nil) throws {
    let path = credentialsPath(baseDirectory: baseDirectory)
    if FileManager.default.fileExists(atPath: path.path) {
      try FileManager.default.removeItem(at: path)
    }
  }

  // MARK: - Permission Helpers

  /// Ensure *directory* exists with mode 0o700.
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
      // Existing directory — correct permissions iff too broad.
      tightenDirectoryPermissions(at: url)
    }
  }

  /// Set the file's POSIX permissions to 0o600 (owner r/w only).
  static func setSecureFilePermissions(at url: URL) throws {
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: 0o600)],
      ofItemAtPath: url.path
    )
  }

  /// If the file has broader-than-0o600 permissions, tighten them.
  private static func tightenFilePermissions(at url: URL) {
    guard let current = try? FileManager.default.attributesOfItem(atPath: url.path),
          let mode = current[.posixPermissions] as? NSNumber
    else { return }

    let mask = 0o077  // bits other than owner
    if mode.intValue & mask != 0 {
      try? setSecureFilePermissions(at: url)
    }
  }

  /// If the directory has broader-than-0o700 permissions, tighten them.
  private static func tightenDirectoryPermissions(at url: URL) {
    guard let current = try? FileManager.default.attributesOfItem(atPath: url.path),
          let mode = current[.posixPermissions] as? NSNumber
    else { return }

    let mask = 0o077  // bits other than owner
    if mode.intValue & mask != 0 {
      try? FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o700)],
        ofItemAtPath: url.path
      )
    }
  }
}
