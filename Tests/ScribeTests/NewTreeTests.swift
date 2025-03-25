import Testing

@testable import Demo
@testable import Scribe

@MainActor  // UI Block test run on main thread.
@Suite("New Tree Tests")
struct NewTreeTests {
  @Test func newTree() async throws {
    enableTestLogging(write_to_file: true)
    let block = Entry()
    let tree = block.toElement()
    var parser = TreeParser(width: 80, height: 24)
    parser.render(tree)
    let expectedText = #"""
      Hello, I am Scribe.
      Zane was here :0
      Job running: ready
      Nested[text: Hello]
      """#
    let window = Window(expectedText, width: 80, height: 24)
    #expect(window.tiles == parser.tiles)
  }
}

struct Window {
  let height: Int
  let width: Int
  var count = 0

  var tiles: [[Tile]]

  init(_ contents: String, width: Int, height: Int) {
    self.tiles = Array(repeating: Array(repeating: Tile(), count: width), count: height)
    self.height = height
    self.width = width
    let lines = contents.split(separator: "\n")
    for (i, line) in lines.enumerated() {
      count = i
      place("\(line)", i, selected: false)
    }
  }

  private mutating func place(_ text: String, _ index: Int, selected: Bool) {
    // TODO why even take the index in if we aren't going to use it.
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
