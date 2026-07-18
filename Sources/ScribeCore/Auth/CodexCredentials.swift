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

/// Persists Codex credentials to a JSON file under `~/.scribe/`.
public enum CodexCredentialStore {
  private static let credentialsFileName = "codex-credentials.json"

  /// Path to the credentials file.
  public static func credentialsPath() -> URL {
    let base = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".scribe")
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base.appendingPathComponent(credentialsFileName)
  }

  /// Read stored credentials, if any.
  public static func read() throws -> CodexCredential? {
    let path = credentialsPath()
    guard FileManager.default.fileExists(atPath: path.path) else { return nil }
    let data = try Data(contentsOf: path)
    return try JSONDecoder().decode(CodexCredential.self, from: data)
  }

  /// Write credentials to disk.
  public static func write(_ credential: CodexCredential) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(credential)
    try data.write(to: credentialsPath(), options: .atomic)
  }

  /// Remove stored credentials (logout).
  public static func delete() throws {
    let path = credentialsPath()
    if FileManager.default.fileExists(atPath: path.path) {
      try FileManager.default.removeItem(at: path)
    }
  }
}
