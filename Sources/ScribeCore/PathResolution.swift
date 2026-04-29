import Foundation

/// Resolves agent/tool path strings into ``ScribeFilePath`` instances with consistent rules.
enum PathResolution {
  struct PathError: Error, CustomStringConvertible {
    let description: String
  }

  static func resolve(reading path: String) throws -> ScribeFilePath {
    try resolve(path: path, mustExist: true, isDirectory: nil)
  }

  static func resolve(writing path: String) throws -> ScribeFilePath {
    try resolve(path: path, mustExist: false, isDirectory: nil)
  }

  static func resolve(existingDirectory path: String) throws -> ScribeFilePath {
    try resolve(path: path, mustExist: true, isDirectory: true)
  }

  private static func resolve(path: String, mustExist: Bool, isDirectory: Bool?) throws
    -> ScribeFilePath
  {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw PathError(description: "path is empty")
    }

    let cwdURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL

    let combinedURL: URL
    if trimmed.hasPrefix("/") {
      combinedURL = URL(fileURLWithPath: trimmed).standardizedFileURL
    } else {
      combinedURL = cwdURL.appendingPathComponent(trimmed).standardizedFileURL
    }

    let resolvedPath = combinedURL.resolvingSymlinksInPath().path

    if mustExist {
      var isDir: ObjCBool = false
      guard FileManager.default.fileExists(atPath: resolvedPath, isDirectory: &isDir) else {
        throw PathError(description: "path does not exist: \(trimmed)")
      }
      if let isDirectory {
        guard isDir.boolValue == isDirectory else {
          throw PathError(
            description: "expected \(isDirectory ? "directory" : "file") at \(trimmed)")
        }
      }
    }

    return ScribeFilePath(resolvedPath)
  }

  /// Produces a filesystem path string suitable for `URL(fileURLWithPath:)` and `FileManager`.
  static func fileSystemPath(_ path: ScribeFilePath) -> String {
    path.withCString { String(cString: $0) }
  }
}
