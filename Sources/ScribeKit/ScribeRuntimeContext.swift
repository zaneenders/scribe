import Foundation
import SystemPackage

public struct ScribeRuntimeContext: Sendable, Equatable {

  public var paths: ScribePaths

  public var configurationFile: FilePath?

  public var defaultWorkingDirectory: String

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
