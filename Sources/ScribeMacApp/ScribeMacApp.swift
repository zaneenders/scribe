#if os(macOS)
import Chroma
import Foundation
import MetalBackend
import ScribeBlocks

@main
struct ScribeMacApp {
  @MainActor
  static func main() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.contains("--help") || arguments.contains("-h") {
      print("usage: scribe-mac")
      print("Launches Scribe in a native Metal window.")
      return
    }
    guard arguments.isEmpty else {
      throw LaunchError.message("Unexpected arguments: \(arguments.joined(separator: " "))")
    }
    do {
      try AppConsoleLog.start()
    } catch {
      AppConsoleLog.event("log.open.failed error=\(error)")
    }
    do {
      try ScribeMetalApp.main()
      AppConsoleLog.event("app.run.returned")
    } catch {
      AppConsoleLog.event("startup.failed error=\(error)")
      throw error
    }
  }
}

private struct ScribeMetalApp: MetalApp {
  var title: String { "Scribe" }
  var windowSize: Size { Size(width: 1100, height: 760) }
  var keyBindings: KeyBindings { ScribeBlock.keyBindings }
  var frameObserver: FrameObserver? { ScribeSceneCapture.shared.enable() }
  var body: some Block { ScribeBlock() }
}

private enum LaunchError: Error, CustomStringConvertible {
  case message(String)
  var description: String {
    switch self {
    case .message(let text): text
    }
  }
}
#endif
