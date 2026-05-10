import SystemPackage

#if canImport(System)
import System
#endif

#if canImport(System)
public typealias ScribeFilePath = System.FilePath
#else
public typealias ScribeFilePath = SystemPackage.FilePath
#endif

extension ScribeFilePath {
  /// Filesystem path string for use with `URL(fileURLWithPath:)` and `FileManager`.
  public var fileSystemPath: String {
    withCString { String(cString: $0) }
  }
}
