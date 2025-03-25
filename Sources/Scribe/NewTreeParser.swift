struct TestTreeParser {

  var width: Int
  var height: Int
  var tiles: [[Tile]]
  var count = 0

  init(width: Int, height: Int) {
    self.height = height
    self.width = width
    self.tiles = Array(repeating: Array(repeating: Tile(), count: width), count: height)
  }

  mutating func render(_ node: Element) {
    switch node {
    case let .composed(e):
      render(e)
    case let .wrapped(e, action):
      render(e)
    case let .group(children):
      for child in children {
        render(child)
      }
    case let .text(text, action):
      place(text, count, selected: false)
      count += 1
    }
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

struct NewTreeRenderer: Renderer {
  var result: [String] = []
  let height: Int
  let width: Int
  var tiles: [[Tile]]

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

  init(width: Int, height: Int) {
    self.height = height
    self.width = width
    self.tiles = Array(repeating: Array(repeating: Tile(), count: width), count: height)
  }

  mutating func view(_ block: borrowing some Block, with state: BlockState) {
    let tree = convert(block)
    var parser = TestTreeParser(width: width, height: height)

    parser.render(tree)
    self.tiles = parser.tiles
  }
}

indirect enum Element {
  case text(String, BlockAction?)
  case wrapped(Element, BlockAction?)
  case group([Element])
  case composed(Element)
}

@MainActor
func convert(_ block: some Block) -> Element {
  if let str = block as? String {
    return .text(str, nil)
  } else if let text = block as? Text {
    return .text(text.text, nil)
  } else if let actionBlock = block as? any ActionBlock {
    return .wrapped(convert(actionBlock.component), actionBlock.action)
  } else if let arrayBlock = block as? any ArrayBlocks {
    let children: [any Block] = arrayBlock._children
    var group: [Element] = []
    for child in children {
      group.append(convert(child))
    }
    return .group(group)
  } else if let tupleArray = block as? any TupleBlocks {
    let children: [any Block] = tupleArray._children
    var group: [Element] = []
    for child in children {
      group.append(convert(child))
    }
    return .group(group)
  } else {
    return .composed(convert(block.component))
  }
}
