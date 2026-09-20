import Foundation
import SystemPackage

/// Explicit runtime inputs for opening Scribe sessions without consulting
/// process environment variables or the current working directory.
///
/// Library and headless-server callers construct a context and pass it to
/// `ConfigLoader.load(paths:configurationFile:profileOverride:)` and
/// `ScribeSessionBootstrap.open(context:...)`. The environment-resolving
/// convenience APIs are standalone wrappers that delegate to these explicit
/// overloads.
public struct ScribeRuntimeContext: Sendable, Equatable {

  /// Data home holding the profile manifest, sessions directory, and logs.
  public var paths: ScribePaths

  /// Configuration file to load. When `nil`, the profile manifest inside
  /// `paths` is used (and a default is written there if missing).
  public var configurationFile: FilePath?

  /// Working directory used for new sessions and as the resume fallback.
  public var defaultWorkingDirectory: String

  /// Scribe version recorded in session metadata and logs.
  public var version: String

  public init(
    paths: ScribePaths,
    configurationFile: FilePath? = nil,
    defaultWorkingDirectory: String,
    version: String
  ) {
    self.paths = paths
    self.configurationFile = configurationFile
    self.defaultWorkingDirectory = defaultWorkingDirectory
    self.version = version
  }
}
