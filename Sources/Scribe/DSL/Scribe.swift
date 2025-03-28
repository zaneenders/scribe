import Logging
import SystemPackage

/// The ``Scribe`` protocol is the starting point of your configuration, you
/// can pass in your ``Block`` structure to the ``entry`` field and optional
/// update the other parameters as you like.
@MainActor
public protocol Scribe {
  init()
  associatedtype MainWindow: Window
  @WindowBuilder var window: MainWindow { get }

  /// You can optional overwrite this path with a different log path.
  /// I may make this a config.
  @available(*, deprecated, message: "Beta")
  var logPath: FilePath { get }
  @available(*, deprecated, message: "Beta")
  var logLevel: Logger.Level { get }
  // Kinda want the ability to add your own logger?
}

/// Default configuration.
extension Scribe {
  // Default log path
  public var logPath: FilePath {
    /*
    TODO set this to a .scribe directory in the user home directory that we
    will setup regardless if you are developing scribe or not.
    */
    FilePath("scribe.log")
  }
  // Outputs log
  public var logLevel: Logger.Level {
    .warning
  }
}
