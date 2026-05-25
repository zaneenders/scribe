#if canImport(System)
import System
import SystemPackage

enum SubprocessFilePathBridge {
  static func executable(_ path: SystemPackage.FilePath) -> System.FilePath {
    System.FilePath(path.string)
  }

  static func workingDirectory(_ path: SystemPackage.FilePath?) -> System.FilePath? {
    path.map { System.FilePath($0.string) }
  }
}
#else
import SystemPackage

enum SubprocessFilePathBridge {
  static func executable(_ path: SystemPackage.FilePath) -> SystemPackage.FilePath {
    path
  }

  static func workingDirectory(_ path: SystemPackage.FilePath?) -> SystemPackage.FilePath? {
    path
  }
}
#endif
