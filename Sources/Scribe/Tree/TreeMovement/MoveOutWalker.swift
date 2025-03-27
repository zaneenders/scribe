struct MoveOutWalker: L2ElementWalker {

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

  mutating func walkText(_ text: String, _ binding: L2Binding?) {
    runBefore()
    Log.debug("\(stateString)")
    runAfter()
  }

  mutating func beforeGroup(_ group: [L2Element], _ binding: L2Binding?) {
    Log.debug("\(stateString) \(group)")
    runBefore()
  }

  mutating func walkGroup(_ group: [L2Element], _ binding: L2Binding?) {
    let ourHash = currentHash
    beforeGroup(group, binding)
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
    afterGroup(group, binding)
  }

  mutating func afterGroup(_ group: [L2Element], _ binding: L2Binding?) {
    runAfter()
  }

  private mutating func runBefore() {}

  private mutating func runAfter() {
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
