import Chroma
import MetalBackend
import ScribeBlocks

@main
struct ScribeMacApp: MetalApp {
  var title: String { "Scribe" }
  var windowSize: Size { Size(width: 1100, height: 760) }
  var minimumRefreshRate: Double { 30 }

  var keyBindings: KeyBindings { ScribeBlock.keyBindings }

  @MainActor var body: some Block {
    ScribeBlock()
  }
}
