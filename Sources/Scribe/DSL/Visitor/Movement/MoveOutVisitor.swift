struct MoveOutVisitor: RawVisitor {

  private let startingSelection: Hash

  init(state: BlockState) {
    self.state = state
    self.startingSelection = state.selected!
    Log.debug("\(self.startingSelection)")
  }

  private(set) var state: BlockState
  var currentHash: Hash = hash(contents: "0")

  private var atSelected: Bool {
    startingSelection == currentHash
  }

  private var currentSelected: Bool {
    self.state.selected == currentHash
  }

  var mode: State = .findingSelected

  enum State {
    case findingSelected
    case foundSelected
    case selectionUpdated
  }

  mutating func visitTuple<each Component: Block>(_ tuple: _TupleBlock<repeat each Component>) {
    let ourHash = currentHash
    beforeTuple(tuple)
    var index = 0
    for child in repeat (each tuple.children) {
      switch mode {
      case .findingSelected:
        currentHash = hash(contents: "\(ourHash)\(#function)\(index)")
        visit(child)
      case .foundSelected, .selectionUpdated:
        ()
      }
      index += 1
    }
    currentHash = ourHash
    afterTuple(tuple)
  }

  mutating func visitArray<B: Block>(_ array: _ArrayBlock<B>) {
    let ourHash = currentHash
    beforeArray(array)
    for (index, child) in array.children.enumerated() {
      switch mode {
      case .findingSelected:
        currentHash = hash(contents: "\(ourHash)\(#function)\(index)")
        visit(child)
      case .foundSelected, .selectionUpdated:
        ()
      }
    }
    currentHash = ourHash
    afterArray(array)
  }

  mutating func visitModified<W: Block>(_ modified: Modified<W>) {
    let ourHash = currentHash
    beforeModified(modified)
    currentHash = hash(contents: "\(ourHash)\(#function)")
    visit(modified.wrapped)
    currentHash = ourHash
    afterModified(modified)
  }

  mutating func visitBlock(_ block: some Block) {
    let ourHash = currentHash
    beforeBlock(block)
    currentHash = hash(contents: "\(ourHash)\(#function)")
    visit(block.component)
    currentHash = ourHash
    afterBlock(block)
  }

  //MARK: before after
  mutating func runBefore() {

  }

  private var stateString: String {
    "\(mode) starting:\(atSelected) current:\(currentSelected) \(currentHash)"
  }

  mutating func runAfter() {
    switch mode {
    case .findingSelected:
      if atSelected {
        self.mode = .foundSelected
        Log.debug("\(stateString) Selection Found")
      }
    case .foundSelected:
      state.selected = currentHash
      self.mode = .selectionUpdated
      Log.debug("\(stateString) Selection changed")
    case .selectionUpdated:
      ()
    }
  }

  mutating func visitText(_ text: Text) {
    runBefore()
    Log.debug("\(stateString)")
    runAfter()
  }

  mutating func beforeTuple<each Component: Block>(_ tuple: _TupleBlock<repeat each Component>) {
    Log.debug("\(stateString) \(tuple)")
    runBefore()
  }

  mutating func afterTuple<each Component>(_ tuple: _TupleBlock<repeat each Component>)
  where repeat each Component: Block {
    Log.debug("\(stateString) \(tuple)")
    runAfter()
  }

  mutating func beforeArray<B: Block>(_ array: _ArrayBlock<B>) {
    Log.debug("\(stateString) \(array)")
    runBefore()
  }

  mutating func afterArray<B>(_ array: _ArrayBlock<B>) where B: Block {
    Log.debug("\(stateString) \(array)")
    runAfter()
  }

  mutating func beforeModified<W: Block>(_ modified: Modified<W>) {
    Log.debug("\(stateString) \(modified)")
    runBefore()
  }

  mutating func afterModified<W>(_ modified: Modified<W>) where W: Block {
    Log.debug("\(stateString) \(modified)")
    runAfter()
  }

  mutating func beforeBlock(_ block: some Block) {
    Log.debug("\(stateString) \(block)")
    runBefore()
  }

  mutating func afterBlock(_ block: some Block) {
    Log.debug("\(stateString) \(block)")
    runAfter()
  }
}
