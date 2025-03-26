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

  mutating func beforeWrapped(_ element: L1Element, _ action: BlockAction?) {
    setFirstSelection()
  }

  mutating func afterWrapped(_ element: L1Element, _ action: BlockAction?) {
    // ignored
  }

  mutating func beforeGroup(_ group: [L1Element]) {
    setFirstSelection()
  }

  mutating func afterGroup(_ group: [L1Element]) {
    // ignored
  }

  mutating func beforeComposed(_ composed: L1Element) {
    setFirstSelection()
  }

  mutating func afterComposed(_ composed: L1Element) {
    // ignored
  }

  private mutating func setFirstSelection() {
    if first {
      self.state.selected = currentHash
      first = false
    }
  }
}
