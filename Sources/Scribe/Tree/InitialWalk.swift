struct InitialWalk: L1HashWalker {

  private var first: Bool
  private(set) var state: BlockState
  var currentHash: Hash

  init(state: BlockState, first: Bool) {
    self.first = first
    self.state = state
    self.currentHash = hash(contents: "0")
  }

  mutating func walkText(_ text: String) {
    setFirstSelection()
  }

  mutating func beforeWrapped(_ element: L1Element, _ key: String, _ action: BlockAction?) {
    setFirstSelection()
  }

  mutating func afterWrapped(_ element: L1Element, _ key: String, _ action: BlockAction?) {
    // ignored
  }

  mutating func beforeGroup(_ group: [L1Element]) {
    setFirstSelection()
  }

  mutating func afterGroup(_ group: [L1Element]) {
    // ignored
  }

  private mutating func setFirstSelection() {
    if first {
      self.state.selected = currentHash
      first = false
    }
  }
}
