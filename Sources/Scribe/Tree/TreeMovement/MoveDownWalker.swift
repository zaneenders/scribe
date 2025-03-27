struct MoveDownWalker: L2ElementWalker {

  enum State {
    case findingSelected
    case breakOutOfChild
    case foundSelected
    case selectionUpdated
  }

  private let startingSelection: Hash
  private(set) var state: BlockState
  var mode: State = .findingSelected
  var areChildNode = false
  var currentHash: Hash = hash(contents: "0")

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
    runBefore()
  }

  mutating func walkGroup(_ group: [L2Element], _ binding: L2Binding?) {
    let ourHash = currentHash
    beforeGroup(group, binding)
    areChildNode = true
    for (index, element) in group.enumerated() {
      switch mode {
      case .breakOutOfChild:
        if group.count > 1 {
          mode = .foundSelected
        } else {
          return  // break into parent node.
        }
        currentHash = hash(contents: "\(ourHash)\(#function)\(index)")
        walk(element)
      case .findingSelected:
        currentHash = hash(contents: "\(ourHash)\(#function)\(index)")
        walk(element)
      case .foundSelected, .selectionUpdated:
        ()
      }
    }
    areChildNode = false
    currentHash = ourHash
    afterGroup(group, binding)
  }

  mutating func afterGroup(_ group: [L2Element], _ binding: L2Binding?) {
    runAfter()
  }

  private mutating func runAfter() {}

  private mutating func runBefore() {
    switch mode {
    case .findingSelected:
      if atSelected {
        if areChildNode {
          self.mode = .breakOutOfChild
        } else {
          self.mode = .foundSelected
        }
        Log.debug("\(stateString) Selection Found")
      }
    case .breakOutOfChild:
      ()
    case .foundSelected:
      state.selected = currentHash
      self.mode = .selectionUpdated
      Log.debug("\(stateString) Selection changed")
    case .selectionUpdated:
      ()
    }
  }
}
