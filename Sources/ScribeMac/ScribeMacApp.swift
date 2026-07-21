import Chroma
import MetalBackend

@main
struct ScribeMacApp: MetalApp {
  var title: String { "Scribe" }
  var windowSize: Size { Size(width: 1100, height: 760) }

  var body: some Block {
    Text("Scribe for macOS — bootstrapping…")
      .foregroundColor(.white)
      .padding(16)
  }
}
