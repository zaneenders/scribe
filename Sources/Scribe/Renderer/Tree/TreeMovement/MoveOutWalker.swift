struct MoveOutWalker: L1ElementWalker {

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

  private var stateString: String {
    "\(mode) starting:\(atSelected) current:\(currentSelected) \(currentHash)"
  }

  mutating func beforeWrapped(_ element: L1Element, _ key: String, _ action: BlockAction?) {
    Log.debug("\(stateString) \(element), \(action != nil)")
    runBefore()
  }

  mutating func walkWrapped(_ element: L1Element, _ key: String, _ action: BlockAction?) {
    beforeWrapped(element, key, action)
    let ourHash = currentHash
    currentHash = hash(contents: "\(ourHash)\(#function)")
    walk(element)
    currentHash = ourHash
    afterWrapped(element, key, action)
  }

  mutating func afterWrapped(_ element: L1Element, _ key: String, _ action: BlockAction?) {
    Log.debug("\(stateString) \(element), \(action != nil)")
    runAfter()
  }

  mutating func beforeGroup(_ group: [L1Element]) {
    Log.debug("\(stateString) \(group)")
    runBefore()
  }

  mutating func walkGroup(_ group: [L1Element]) {
    let ourHash = currentHash
    beforeGroup(group)
    for (index, element) in group.enumerated() {
      switch mode {
      case .findingSelected:
        currentHash = hash(contents: "\(ourHash)\(#function)\(index)")
        walk(element)
      case .foundSelected, .selectionUpdated:
        ()
      }
    }
    currentHash = ourHash
    afterGroup(group)
  }

  mutating func afterGroup(_ group: [L1Element]) {
    Log.debug("\(stateString) \(group)")
    runAfter()
  }

  mutating func walkText(_ text: String) {
    runBefore()
    Log.debug("\(stateString)")
    // self.mode = .selectionUpdated
    runAfter()
  }

  mutating func runBefore() {

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
}
