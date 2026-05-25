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

@discardableResult
private func _posixStat(_ path: String, _ buf: UnsafeMutablePointer<CStat>) -> Int32 {
  stat(path, buf)
}

public struct FileStat {
  public let exists: Bool
  public let isDirectory: Bool
  public let size: Int64
  public let modificationDate: Date

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

  public static func isDirectory(_ path: FilePath) -> Bool {
    stat(path).isDirectory
  }

  public static func fileSize(_ path: FilePath) -> Int64 {
    stat(path).size
  }
}

public func createDirectoryWithIntermediates(_ path: FilePath) throws {

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

      break
    }
    current = parent
  }

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

  public var modificationDate: Date {
    FileStat.stat(self).modificationDate
  }

  public var fileSize: Int64 {
    FileStat.fileSize(self)
  }

  public static var currentDirectory: FilePath {
    FilePath(String(cString: getcwd(nil, 0)!))
  }
}

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
