/// protocol for moving over the tree and viewing state if the current block is
/// selected or not.
protocol SelectionVisitor: HashVisitor {
  var state: BlockState { get }
  var isSelected: Bool { get set }
  mutating func leafNode(_ text: Text)
}

extension SelectionVisitor {

  mutating func leafNode(_ text: Text) {}

  mutating func visitText(_ text: Text) {
    updateSelected(text)
    leafNode(text)
    resetSelected()
  }

  mutating func updateSelected(_ block: some Block) {
    if !isSelected {
      isSelected = state.selected == currentHash
    }
  }

  mutating func resetSelected() {
    if currentHash == state.selected {
      isSelected = false
    }
  }

  mutating func beforeArray<B>(_ array: _ArrayBlock<B>) where B: Block {
    updateSelected(array)
  }

  mutating func afterArray<B>(_ array: _ArrayBlock<B>) where B: Block {
    resetSelected()
  }

  mutating func beforeBlock(_ block: some Block) {
    updateSelected(block)
  }

  mutating func afterBlock(_ block: some Block) {
    resetSelected()
  }

  mutating func beforeModified<W>(_ modified: Modified<W>) where W: Block {
    updateSelected(modified)
  }

  mutating func afterModified<W>(_ modified: Modified<W>) where W: Block {
    resetSelected()
  }

  mutating func beforeTuple<each Component>(_ tuple: _TupleBlock<repeat each Component>)
  where repeat each Component: Block {
    updateSelected(tuple)
  }

  mutating func afterTuple<each Component>(_ tuple: _TupleBlock<repeat each Component>)
  where repeat each Component: Block {
    resetSelected()
  }
}
