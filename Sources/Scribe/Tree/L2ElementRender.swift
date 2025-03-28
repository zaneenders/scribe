struct L2ElementRender: L2SelectionWalker {

  internal var isSelected: Bool = false
  var currentHash: Hash
  var width: Int
  var height: Int
  var tiles: [[Tile]]
  var count = 0
  let state: BlockState

  init(state: BlockState, width: Int, height: Int) {
    self.state = state
    self.height = height
    self.width = width
    self.tiles = Array(repeating: Array(repeating: Tile(), count: width), count: height)
    currentHash = hash(contents: "\(0)")
  }

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

  // Used for helping create test.
  // Doesn't use .ascii
  var _raw: String {
    var out = ""
    for row in tiles {
      var line = ""
      for rune in row {
        line += "\(rune.symbol)"
      }
      line += "\n"
      out += line
    }
    out.removeLast()  // remove last newline.
    return out
  }

  mutating func leafNode(_ text: String) {
    place(text, count, selected: isSelected)
    count += 1
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
      guard index < height else {
        Log.error("Too many rows \(text)")
        break place_loop
      }
      tiles[index][x + i] = Tile(symbol: char, fg: fg, bg: bg)
      placed += 1
    }
    x += placed
  }
}
