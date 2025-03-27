struct MoveUpWalker: L2ElementWalker {

  enum State {
    case findingSelected
    case breakOutOfChild
    case foundSelected
    case selectionUpdated
  }

  private let startingSelection: Hash
  private(set) var state: BlockState
  var currentHash: Hash = hash(contents: "0")
  var mode: State = .findingSelected
  var areChildNode = false

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
    areChildNode = true
    var prevIndex: Int? = nil
    for (index, element) in group.enumerated() {
      currentHash = hash(contents: "\(ourHash)\(#function)\(index)")
      walk(element)
      switch mode {
      case .breakOutOfChild, .foundSelected:
        if let prevIndex {
          mode = .foundSelected
          currentHash = hash(contents: "\(ourHash)\(#function)\(prevIndex)")
          walk(group[prevIndex])
        } else {
          // only one child.
        }
        return
      case .findingSelected, .selectionUpdated:
        ()
      }
      prevIndex = index
    }
    areChildNode = false
    currentHash = ourHash
    afterGroup(group, binding)
  }

  mutating func afterGroup(_ group: [L2Element], _ binding: L2Binding?) {
    runAfter()
  }

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

  private mutating func runAfter() {}
}
