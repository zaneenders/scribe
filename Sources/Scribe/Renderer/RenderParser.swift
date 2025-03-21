/// Hold the state of the ``Block`` from the @State and @Tracked variables.
@available(*, deprecated, message: "Moving towards TerminalRenderer.")
struct RenderParser {
  // TODO remove un accessed values from cache.
  private(set) var state: BlockState
  var currentHash: Hash

  init(state: BlockState, width: Int, height: Int) {
    self.state = state
    self.tiles = Array(repeating: Array(repeating: Tile(), count: width), count: height)
    self.width = width
    self.height = height
    self.currentHash = hash(contents: "0")
  }

  var width: Int
  var height: Int
  var tiles: [[Tile]]
  var count = 0

  var ascii: String {
    var out = ""
    for row in tiles {
      var line = ""
      for rune in row {
        line += rune.ascii
      }
      line += "\n"
      out += line
    }
    out.removeLast()  // remove last newline.
    return out
  }

  var isSelected: Bool = false

  mutating func updateSize(width: Int, height: Int) {
    self.count = 0
    self.tiles = Array(repeating: Array(repeating: Tile(), count: width), count: height)
    self.width = width
    self.height = height
  }

  private mutating func place(_ text: String, _ index: Int, selected: Bool) {
    let fg: Chroma.Color
    let bg: Chroma.Color
    if selected {
      fg = .yellow
      bg = .purple
    } else {
      fg = .blue
      bg = .green
    }
    var placed = 0
    var x = 0
    place_loop: for (i, char) in text.enumerated() {
      guard x + i < width else {
        Log.error("Frame width exceeded with \(text)")
        break place_loop
      }
      guard char != "\n" else {
        Log.error("Found newline in word \(text)")
        break place_loop
      }
      guard count < height else {
        Log.error("Too many rows \(text)")
        break place_loop
      }
      tiles[count][x + i] = Tile(symbol: char, fg: fg, bg: bg)
      placed += 1
    }
    x += placed
  }
}

extension RenderParser: SelectionVisitor {

  mutating func leafNode(_ text: Text) {
    Log.trace("\(isSelected) \(text.text)")
    place(text.text, count, selected: isSelected)
    count += 1
  }
}
