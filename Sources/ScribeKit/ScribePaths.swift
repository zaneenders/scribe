import Foundation
import SystemPackage

public struct ScribePaths: Sendable {

  public let dataHome: FilePath

  public let profileManifestPath: FilePath

  public let sessionsDirectory: FilePath

  public var sessionsDirectoryPath: String { sessionsDirectory.string }

  public var dataHomePath: String { dataHome.string }

  public init(dataHome: FilePath) {
    self.dataHome = dataHome
    self.profileManifestPath = dataHome.appendingPathComponent("scribe.config.json")
    self.sessionsDirectory = dataHome.appendingPathComponent("sessions")
  }

  public static func resolve() -> ScribePaths {
    ScribePaths(dataHome: FilePath(resolveDataHome()))
  }

  public func sessionDirectory(sessionId: UUID) -> FilePath {
    sessionsDirectory.appendingPathComponent(sessionId.uuidString)
  }

  public func logFile(sessionId: UUID) -> FilePath {
    sessionDirectory(sessionId: sessionId).appendingPathComponent("scribe.log")
  }

  public func messagesFile(sessionId: UUID) -> FilePath {
    sessionDirectory(sessionId: sessionId).appendingPathComponent("messages.jsonl")
  }

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
