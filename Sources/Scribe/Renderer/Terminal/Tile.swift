/// Represents one monospaced unit of the screen.
struct Tile: Equatable {
  let symbol: Character
  let fg: Chroma.Color
  let bg: Chroma.Color

  init(_ symbol: Character = " ") {
    self.symbol = symbol
    self.fg = .default
    self.bg = .default
  }

  init(symbol: Character, fg: Chroma.Color, bg: Chroma.Color) {
    self.symbol = symbol
    self.fg = fg
    self.bg = bg
  }

  var ascii: String {
    Chroma.wrap("\(symbol)", fg, bg)
  }
}
