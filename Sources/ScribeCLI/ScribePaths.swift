import Foundation
import SystemPackage

// MARK: - ScribePaths

/// Centralized path resolution for Scribe.  The data home defaults to `~/.scribe/`
/// and can be overridden with the `SCRIBE_HOME` environment variable.  Config,
/// sessions, and per-session logs all live under that directory.
public struct ScribePaths: Sendable {
  /// Root data directory.  Defaults to `~/.scribe/`; override with `SCRIBE_HOME`.
  public let dataHome: FilePath

  /// Absolute path to the default config file: `{dataHome}/scribe-config.json`.
  public let defaultConfigPath: FilePath

  /// Absolute path for session storage: `{dataHome}/sessions/`.
  public let sessionsDirectory: FilePath

  /// String form of ``sessionsDirectory`` for APIs that still take paths as `String`.
  public var sessionsDirectoryPath: String { sessionsDirectory.string }

  /// String form of ``dataHome``.
  public var dataHomePath: String { dataHome.string }

  // MARK: - Init

  public init(dataHome: FilePath) {
    self.dataHome = dataHome
    self.defaultConfigPath = dataHome.appendingPathComponent("scribe-config.json")
    self.sessionsDirectory = dataHome.appendingPathComponent("sessions")
  }

  // MARK: - Static factory

  /// Resolve all Scribe paths from the current environment.
  public static func resolve() -> ScribePaths {
    ScribePaths(dataHome: FilePath(resolveDataHome()))
  }

  /// `{sessionsDirectory}/{sessionId}/`
  public func sessionDirectory(sessionId: UUID) -> FilePath {
    sessionsDirectory.appendingPathComponent(sessionId.uuidString)
  }

  /// `{sessionsDirectory}/{sessionId}/scribe.log`
  public func logFile(sessionId: UUID) -> FilePath {
    sessionDirectory(sessionId: sessionId).appendingPathComponent("scribe.log")
  }

  /// `{sessionsDirectory}/{sessionId}/messages.jsonl`
  public func messagesFile(sessionId: UUID) -> FilePath {
    sessionDirectory(sessionId: sessionId).appendingPathComponent("messages.jsonl")
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
