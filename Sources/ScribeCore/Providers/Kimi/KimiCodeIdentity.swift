import Foundation

enum KimiCodeIdentity {
  static let platform = "kimi_code_cli"
  static let userAgentProduct = "kimi-code-cli"

  static func requestHeaders(version: String = "1.0") -> [String: String] {
    [
      "User-Agent": "\(userAgentProduct)/\(version)",
      "X-Msh-Platform": platform,
      "X-Msh-Version": version,
      "X-Msh-Device-Name": Host.current().localizedName ?? "unknown",
      "X-Msh-Device-Model": deviceModel(),
      "X-Msh-Os-Version": ProcessInfo.processInfo.operatingSystemVersionString,
      "X-Msh-Device-Id": deviceID(),
    ]
  }

  private static func deviceID() -> String {
    let home =
      ProcessInfo.processInfo.environment["SCRIBE_HOME"]
      .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .flatMap { $0.isEmpty ? nil : NSString(string: $0).expandingTildeInPath }
      ?? NSString(string: "~/.scribe").expandingTildeInPath
    let path = URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent("device_id")
    if let existing = try? String(contentsOf: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
      !existing.isEmpty
    {
      return existing
    }
    let id = UUID().uuidString
    try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? id.write(to: path, atomically: true, encoding: .utf8)
    return id
  }

  private static func deviceModel() -> String {
    #if os(macOS)
    return "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
    #elseif os(Linux)
    return "Linux \(ProcessInfo.processInfo.operatingSystemVersionString)"
    #else
    return ProcessInfo.processInfo.operatingSystemVersionString
    #endif
  }
}
