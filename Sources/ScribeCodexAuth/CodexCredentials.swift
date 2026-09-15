import Foundation

public struct CodexCredential: Sendable, Codable {
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
    let path = credentialsPath(baseDirectory: baseDirectory)
    guard FileManager.default.fileExists(atPath: path.path) else { return nil }

    tightenFilePermissions(at: path)

    let data = try Data(contentsOf: path)
    return try JSONDecoder().decode(CodexCredential.self, from: data)
  }

  public static func write(_ credential: CodexCredential, baseDirectory: URL? = nil) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(credential)
    let path = credentialsPath(baseDirectory: baseDirectory)
    try data.write(to: path, options: .atomic)
    try setSecureFilePermissions(at: path)
  }

  public static func delete(baseDirectory: URL? = nil) throws {
    let path = credentialsPath(baseDirectory: baseDirectory)
    if FileManager.default.fileExists(atPath: path.path) {
      try FileManager.default.removeItem(at: path)
    }
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
