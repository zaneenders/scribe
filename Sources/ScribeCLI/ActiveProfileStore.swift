import Foundation
import ScribeCore
import SystemPackage

public enum ActiveProfileStore {
  public struct File: Codable, Sendable, Equatable {
    public var activeProfile: String

    public init(activeProfile: String) {
      self.activeProfile = activeProfile
    }
  }

  private static let fileName = "active-profile.json"

  public static func path(in paths: ScribePaths) -> FilePath {
    paths.activeProfilePath
  }

  public static func read(from paths: ScribePaths) throws -> String? {
    let path = path(in: paths)
    guard FileStat.stat(path).exists else { return nil }
    let url = URL(fileURLWithPath: path.string)
    let data = try Data(contentsOf: url)
    let decoded = try JSONDecoder().decode(File.self, from: data)
    let trimmed = decoded.activeProfile.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw ScribeError.configuration(
        key: "activeProfile",
        reason: "`\(fileName)` must contain a non-empty `activeProfile` string."
      )
    }
    return trimmed
  }

  public static func write(_ name: String, paths: ScribePaths) throws {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw ScribeError.configuration(
        key: "activeProfile",
        reason: "Cannot write an empty profile name to `\(fileName)`."
      )
    }
    let path = path(in: paths)
    let payload = File(activeProfile: trimmed)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(payload)
    let url = URL(fileURLWithPath: path.string)
    let dir = url.deletingLastPathComponent()
    try createDirectoryWithIntermediates(FilePath(dir.path))
    try data.write(to: url, options: .atomic)
  }
}
