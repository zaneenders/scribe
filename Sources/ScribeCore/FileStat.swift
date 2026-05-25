import Foundation
import SystemPackage

#if canImport(Darwin)
import Darwin
private typealias CStat = Darwin.stat
#elseif canImport(Glibc)
import Glibc
private typealias CStat = Glibc.stat
#elseif canImport(Musl)
import Musl
private typealias CStat = Musl.stat
#endif


/// Calls POSIX `stat()` on `path`. Returns `0` on success, `-1` on failure
/// (with `errno` set).  Uses the C function directly (not the struct).
@discardableResult
private func _posixStat(_ path: String, _ buf: UnsafeMutablePointer<CStat>) -> Int32 {
  stat(path, buf)
}


/// Synchronous file metadata from POSIX `stat()`.  Use only in contexts that
/// cannot be made async; prefer `_NIOFileSystem` / `FileSystem.shared.info()`
/// everywhere else.
public struct FileStat {
  public let exists: Bool
  public let isDirectory: Bool
  public let size: Int64
  public let modificationDate: Date

  /// Read file metadata for the given path.  Returns a value with
  /// `exists == false` when the path does not exist.
  public static func stat(_ path: FilePath) -> FileStat {
    var s: CStat = CStat()
    let rc = _posixStat(path.string, &s)
    if rc != 0 {
      return FileStat(exists: false, isDirectory: false, size: 0, modificationDate: .distantPast)
    }
    let isDir = (s.st_mode & S_IFMT) == S_IFDIR
#if canImport(Darwin)
    let mtime = Date(
      timeIntervalSince1970: Double(s.st_mtimespec.tv_sec)
        + Double(s.st_mtimespec.tv_nsec) / 1_000_000_000)
#else
    let mtime = Date(
      timeIntervalSince1970: Double(s.st_mtim.tv_sec)
        + Double(s.st_mtim.tv_nsec) / 1_000_000_000)
#endif
    return FileStat(
      exists: true,
      isDirectory: isDir,
      size: Int64(s.st_size),
      modificationDate: mtime)
  }

  /// Returns `true` when the path exists and is a directory.
  public static func isDirectory(_ path: FilePath) -> Bool {
    stat(path).isDirectory
  }

  /// Returns file size in bytes, or `-1` when the path does not exist or
  /// cannot be read.
  public static func fileSize(_ path: FilePath) -> Int64 {
    stat(path).size
  }
}


/// Create a directory and all intermediate directories, analogous to
/// `mkdir -p`.  Returns without error when the directory already exists.
/// Only for the few synchronous contexts that cannot use
/// `FileSystem.shared.createDirectory(at:withIntermediateDirectories:)`.
public func createDirectoryWithIntermediates(_ path: FilePath) throws {
  // Walk up to find the first existing ancestor.
  var missing: [FilePath] = []
  var current = path
  while true {
    let st = FileStat.stat(current)
    if st.exists {
      if st.isDirectory { break }
      throw FileStatError.notDirectory(current)
    }
    missing.append(current)
    let parent = current.removingLastComponent()
    if parent.string == current.string || parent.string == "." {
      // Reached root or an empty path — nothing to create.
      break
    }
    current = parent
  }

  // Create missing directories from the top down.
  for dir in missing.reversed() {
    if mkdir(dir.string, S_IRWXU | S_IRGRP | S_IXGRP | S_IROTH | S_IXOTH) != 0 {
      let err = errno
      if err == EEXIST { continue }
      throw FileStatError.mkdirFailed(dir, err)
    }
  }
}

public enum FileStatError: Error, CustomStringConvertible {
  case notDirectory(FilePath)
  case mkdirFailed(FilePath, Int32)

  public var description: String {
    switch self {
    case .notDirectory(let path):
      return "path exists but is not a directory: \(path.string)"
    case .mkdirFailed(let path, let err):
      return "mkdir failed for \(path.string): errno \(err)"
    }
  }
}

extension FilePath {
  /// Returns the receiver as a `Date` representing the last modification
  /// time, or `.distantPast` when the file cannot be stat'd.
  public var modificationDate: Date {
    FileStat.stat(self).modificationDate
  }

  public var fileSize: Int64 {
    FileStat.fileSize(self)
  }

  /// The current working directory.
  public static var currentDirectory: FilePath {
    FilePath(String(cString: getcwd(nil, 0)!))
  }
}


/// Returns the names of entries in the directory at `path`, excluding "."
/// and "..".  Throws if the path cannot be opened as a directory.
public func listDirectoryContents(_ path: FilePath) throws -> [String] {
  guard let dir = opendir(path.string) else {
    throw FileStatError.mkdirFailed(path, errno)
  }
  defer { closedir(dir) }
  var names: [String] = []
  while let entry = readdir(dir) {
    let name = withUnsafePointer(to: entry.pointee.d_name) { ptr in
      ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN)) {
        String(cString: $0)
      }
    }
    if name == "." || name == ".." { continue }
    names.append(name)
  }
  return names
}
