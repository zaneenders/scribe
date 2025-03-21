@testable import Scribe

struct TestRenderer: Renderer {
  var selected = ""
  var previousVisitor: TestVisitor = TestVisitor(state: BlockState())

  mutating func view(_ block: borrowing some Block, with state: BlockState) {
    var visitor = TestVisitor(state: state)
    visitor.textObjects = [:]
    visitor.visit(block)
    selected = state.selected ?? ""
    previousVisitor = visitor
  }
}

extension TestRenderer {
  struct TestVisitor: SelectionVisitor {

    // Set by the visitor
    var currentHash: Hash
    let state: BlockState
    var blockObjects: [Hash: String]

    init(state: BlockState) {
      self.state = state
      self.currentHash = hash(contents: "\(0)")
      self.blockObjects = [:]
    }

    var textObjects: [Hash: String] = [:]
    var isSelected: Bool = false

    mutating func leafNode(_ text: Text) {
      if isSelected {
        textObjects[currentHash] = "[\(text.text)]"
      } else {
        textObjects[currentHash] = text.text
      }
    }
  }
}
