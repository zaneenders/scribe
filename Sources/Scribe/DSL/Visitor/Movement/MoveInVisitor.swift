struct MoveInVisitor: HashVisitor {

  private let startingSelection: Hash

  init(state: BlockState) {
    self.state = state
    self.startingSelection = state.selected!
    Log.debug("\(self.startingSelection)")
  }

  private(set) var state: BlockState
  var currentHash: Hash = hash(contents: "0")

  var mode: State = .findingSelected

  enum State {
    case findingSelected
    case foundSelected
    case selectionUpdated
  }

  mutating func runBefore() {
    // TODO check that move in is possible.
    switch mode {
    case .findingSelected:
      if atSelected {
        self.mode = .foundSelected
      }
    case .foundSelected:
      state.selected = currentHash
      self.mode = .selectionUpdated
    case .selectionUpdated:
      ()
    }
  }

  private var atSelected: Bool {
    startingSelection == currentHash
  }

  private var currentSelected: Bool {
    self.state.selected == currentHash
  }

  private var stateString: String {
    "\(mode) starting:\(atSelected) current:\(currentSelected) \(currentHash)"
  }

  mutating func runAfter() {

  }

  mutating func visitText(_ text: Text) {
    runBefore()
    Log.debug("\(stateString)")
    self.mode = .selectionUpdated
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

  mutating func beforeEither<A: Block, B: Block>(_ either: _EitherBlock<A, B>) {
    Log.debug("\(stateString) \(either)")
    runBefore()
  }

  mutating func afterEither<A, B>(_ either: _EitherBlock<A, B>) where A: Block, B: Block {
    Log.debug("\(stateString) \(either)")
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
