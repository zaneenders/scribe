/// First parse to setup the initial selection state of the system.
struct InitialParser {
  private var first: Bool
  private(set) var state: BlockState
  var currentHash: Hash

  init(state: BlockState, first: Bool) {
    self.first = first
    self.state = state
    self.currentHash = hash(contents: "0")
  }
}

extension InitialParser: HashVisitor {

  mutating func visitText(_ text: Text) {
    setFirstSelection(text)
  }

  mutating func beforeTuple<each Component: Block>(_ tuple: _TupleBlock<repeat each Component>) {
    setFirstSelection(tuple)
  }

  mutating func beforeArray<B: Block>(_ array: _ArrayBlock<B>) {
    setFirstSelection(array)
  }

  mutating func beforeModified<W: Block>(_ modified: Modified<W>) {
    setFirstSelection(modified)
  }

  mutating func beforeBlock(_ block: some Block) {
    setFirstSelection(block)
  }

  private mutating func setFirstSelection(_ block: some Block) {
    if first {
      self.state.selected = currentHash
      first = false
    }
  }
}
