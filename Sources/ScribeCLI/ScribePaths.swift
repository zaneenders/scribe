import Foundation

// MARK: - ScribePaths

/// Centralized path resolution for Scribe.  The data home defaults to `~/.scribe/`
/// and can be overridden with the `SCRIBE_HOME` environment variable.  Config,
/// sessions, and per-session logs all live under that directory.
public struct ScribePaths: Sendable {
  /// Root data directory.  Defaults to `~/.scribe/`; override with `SCRIBE_HOME`.
  public let dataHome: String

  /// Absolute path to the default config file: `{dataHome}/scribe-config.json`.
  public let defaultConfigPath: String

  /// Absolute path for session storage: `{dataHome}/sessions/`.
  public let sessionsDirectoryPath: String

  // MARK: - Init

  public init(dataHome: String) {
    let homeURL = URL(fileURLWithPath: dataHome, isDirectory: true).standardizedFileURL
    self.dataHome = homeURL.path
    self.defaultConfigPath =
      homeURL
      .appendingPathComponent("scribe-config.json", isDirectory: false).path
    self.sessionsDirectoryPath =
      homeURL
      .appendingPathComponent("sessions", isDirectory: true).path
  }

  // MARK: - Static factory

  /// Resolve all Scribe paths from the current environment.
  public static func resolve() -> ScribePaths {
    ScribePaths(dataHome: resolveDataHome())
  }

  /// `{sessionsDirectoryPath}/{sessionId}/`
  public func sessionDirectory(sessionId: UUID) -> String {
    URL(fileURLWithPath: sessionsDirectoryPath, isDirectory: true)
      .appendingPathComponent(sessionId.uuidString, isDirectory: true)
      .path
  }

  /// `{sessionsDirectoryPath}/{sessionId}/scribe.log`
  public func logFilePath(sessionId: UUID) -> String {
    URL(fileURLWithPath: sessionDirectory(sessionId: sessionId), isDirectory: true)
      .appendingPathComponent("scribe.log", isDirectory: false)
      .path
  }

  // MARK: - Private helpers

  private static func resolveDataHome() -> String {
    if let raw = ProcessInfo.processInfo.environment["SCRIBE_HOME"] {
      let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty {
        return URL(
          fileURLWithPath: NSString(string: trimmed).expandingTildeInPath,
          isDirectory: true
        ).standardizedFileURL.path
      }
    }
    return URL(
      fileURLWithPath: NSString(string: "~/.scribe").expandingTildeInPath,
      isDirectory: true
    ).standardizedFileURL.path
  }
}
