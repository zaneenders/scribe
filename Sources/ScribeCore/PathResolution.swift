import Foundation
import SystemPackage

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
    let fp = FilePath(resolvedPath)

    if mustExist {
      let st = FileStat.stat(fp)
      guard st.exists else {
        throw PathError(description: "path does not exist: \(trimmed)")
      }
      if let isDirectory {
        guard st.isDirectory == isDirectory else {
          throw PathError(
            description: "expected \(isDirectory ? "directory" : "file") at \(trimmed)")
        }
      }
    }

    return fp
  }
}
