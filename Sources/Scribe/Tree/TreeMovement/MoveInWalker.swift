struct MoveInWalker: L1HashWalker {

  enum State {
    case findingSelected
    case foundSelected
    case selectionUpdated
  }

  private let startingSelection: Hash
  private(set) var state: BlockState
  var currentHash: Hash = hash(contents: "0")
  var mode: State = .findingSelected

  init(state: BlockState) {
    self.state = state
    self.startingSelection = state.selected!
    Log.debug("\(self.startingSelection)")
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

  mutating func beforeWrapped(_ element: L1Element, _ key: String, _ action: BlockAction?) {
    Log.debug("\(stateString) \(element), \(action != nil)")
    runBefore()
  }

  mutating func afterWrapped(_ element: L1Element, _ key: String, _ action: BlockAction?) {
    Log.debug("\(stateString) \(element), \(action != nil)")
    runAfter()
  }

  mutating func beforeGroup(_ group: [L1Element]) {
    Log.debug("\(stateString) \(group)")
    runBefore()
  }

  mutating func afterGroup(_ group: [L1Element]) {
    Log.debug("\(stateString) \(group)")
    runAfter()
  }

  mutating func walkText(_ text: String) {
    runBefore()
    Log.debug("\(stateString)")
    self.mode = .selectionUpdated
    runAfter()
  }

  private mutating func runBefore() {
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

  mutating func runAfter() {}
}
