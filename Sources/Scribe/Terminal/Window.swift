/// A window contains a way of drawing ``Tile``s to the terminal window.
/// and is really only interacted with through the ``Terminal``
struct Window: ~Copyable {

    var height: Int {
        tiles.count
    }
    var width: Int {
        tiles[0].count
    }

    /// Represents one monospaced unit of the screen.
    struct Tile {
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

    var tiles: [[Tile]]

    var count: Int {
        var sum = 0
        for row in tiles {
            sum += row.count
        }
        return sum
    }

    init(
        _ width: Int, _ height: Int, _ symbol: Character = " ", _ fg: Chroma.Color = .white,
        _ bg: Chroma.Color = .default
    ) {
        tiles = Array(repeating: Array(repeating: Tile(symbol: symbol, fg: fg, bg: bg), count: width), count: height)
    }

    mutating func resize(_ width: Int, _ height: Int) {
        // TODO only resize if needed
        tiles = Array(repeating: Array(repeating: Tile(), count: width), count: height)
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
}
