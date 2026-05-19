import Foundation
import SystemPackage

/// Resolves agent/tool path strings into `FilePath` instances with consistent rules.
enum PathResolution {
  struct PathError: Error, CustomStringConvertible {
    let description: String
  }

  static func resolve(reading path: String, cwd: FilePath) throws -> FilePath {
    try resolve(path: path, cwd: cwd, mustExist: true, isDirectory: nil)
  }

  static func resolve(writing path: String, cwd: FilePath) throws -> FilePath {
    try resolve(path: path, cwd: cwd, mustExist: false, isDirectory: nil)
  }

  static func resolve(existingDirectory path: String, cwd: FilePath) throws -> FilePath {
    try resolve(path: path, cwd: cwd, mustExist: true, isDirectory: true)
  }

  private static func resolve(
    path: String, cwd: FilePath, mustExist: Bool, isDirectory: Bool?
  ) throws -> FilePath {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw PathError(description: "path is empty")
    }

    let cwdURL = URL(fileURLWithPath: cwd.string, isDirectory: true).standardizedFileURL

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

    return FilePath(resolvedPath)
  }
}
