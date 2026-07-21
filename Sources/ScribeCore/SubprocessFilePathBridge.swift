#if canImport(System)
import System
import SystemPackage

package enum SubprocessFilePathBridge {
  package static func executable(_ path: SystemPackage.FilePath) -> System.FilePath {
    System.FilePath(path.string)
  }

  package static func workingDirectory(_ path: SystemPackage.FilePath?) -> System.FilePath? {
    path.map { System.FilePath($0.string) }
  }
}
#else
import SystemPackage

package enum SubprocessFilePathBridge {
  package static func executable(_ path: SystemPackage.FilePath) -> SystemPackage.FilePath {
    path
  }

  package static func workingDirectory(_ path: SystemPackage.FilePath?) -> SystemPackage.FilePath? {
    path
  }
}
#endif
