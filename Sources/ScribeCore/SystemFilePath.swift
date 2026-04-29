import SystemPackage

#if canImport(System)
import System
#endif

#if canImport(System)
internal typealias ScribeFilePath = System.FilePath
#else
internal typealias ScribeFilePath = SystemPackage.FilePath
#endif

extension ScribeFilePath {
  /// Swift Configuration’s file providers use ``SystemPackage/FilePath`` as a distinct type from ``System/FilePath`` on some platforms.
  var configurationFilePath: SystemPackage.FilePath {
    #if canImport(System)
    SystemPackage.FilePath(string)
    #else
    self
    #endif
  }
}
