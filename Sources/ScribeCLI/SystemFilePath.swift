#if canImport(System)
import System
#endif
import SystemPackage

/// Native swift-system path: ``System/FilePath`` when the System module is available (e.g. Apple platforms), otherwise ``SystemPackage/FilePath``.
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
