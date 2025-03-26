protocol L1SelectionWalker: L1HashWalker {
  var state: BlockState { get }
  var isSelected: Bool { get set }
  mutating func leafNode(_ text: String)
}

extension L1SelectionWalker {

  private mutating func updateSelected() {
    if !isSelected {
      isSelected = state.selected == currentHash
    }
  }

  private mutating func resetSelected() {
    if currentHash == state.selected {
      isSelected = false
    }
  }

  mutating func beforeWrapped(_ element: L1Element, _ action: BlockAction?) {
    updateSelected()
  }

  mutating func afterWrapped(_ element: L1Element, _ action: BlockAction?) {
    resetSelected()
  }

  mutating func beforeGroup(_ group: [L1Element]) {
    updateSelected()
  }

  mutating func afterGroup(_ group: [L1Element]) {
    resetSelected()
  }

  mutating func beforeComposed(_ composed: L1Element) {
    updateSelected()
  }

  mutating func afterComposed(_ composed: L1Element) {
    resetSelected()
  }

  mutating func walkText(_ text: String) {
    updateSelected()
    leafNode(text)
    resetSelected()
  }
}
