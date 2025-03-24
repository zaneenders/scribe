import Testing

@testable import Demo
@testable import Scribe

@MainActor  // UI Block test run on main thread.
@Suite("New Tree Tests")
struct NewTreeTests {
  @Test func newTree() async throws {
    enableTestLogging(write_to_file: false)
    let block = Entry()
    var renderer = NewTreeRenderer()
    renderer.view(block, with: BlockState())
    let expected = [
      "[Composed: start]", "[Group: start]", "[Wrapped, action:true]",
      "[Hello, I am Scribe., action:false]", "[Wrapped: end]", "[Wrapped, action:true]",
      "[Zane was here :0, action:false]", "[Wrapped: end]", "[Wrapped, action:true]",
      "[Job running: ready, action:false]", "[Wrapped: end]", "[Composed: start]",
      "[Nested[text: Hello], action:false]", "[Composed: end]", "[Group: end]", "[Composed: end]",
    ]
    #expect(renderer.result == expected)
  }
}

struct TestTreeParser {
  var nodes: [String] = []
  mutating func view(_ node: Element) {
    switch node {
    case let .composed(e):
      nodes.append("[Composed: start]")
      view(e)
      nodes.append("[Composed: end]")
    case let .wrapped(e, action):
      nodes.append("[Wrapped, action:\(action != nil)]")
      view(e)
      nodes.append("[Wrapped: end]")
    case let .group(children):
      nodes.append("[Group: start]")
      for child in children {
        view(child)
      }
      nodes.append("[Group: end]")
    case let .text(text, action):
      nodes.append("[\(text), action:\(action != nil)]")
    }
  }
}

struct NewTreeRenderer: Renderer {
  var result: [String] = []

  mutating func view(_ block: borrowing some Block, with state: BlockState) {
    let tree = convert(block)
    var parser = TestTreeParser()
    parser.view(tree)
    result = parser.nodes
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
