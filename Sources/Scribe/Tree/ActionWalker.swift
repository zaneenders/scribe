struct ActionWalker: L1HashWalker {

  private(set) var state: BlockState
  private var input: String
  var currentHash: Hash = hash(contents: "0")

  init(state: BlockState, input: String) {
    self.state = state
    self.input = input
  }

  mutating func beforeWrapped(_ element: L1Element, _ key: String, _ action: BlockAction?) {
    Log.debug("\(#function): \(currentHash), \(state.selected)")
    let selected = self.state.selected == currentHash
    if selected && key == input {
      if let action {
        action()
      }
    }
  }

  mutating func afterWrapped(_ element: L1Element, _ key: String, _ action: BlockAction?) {}

  mutating func beforeGroup(_ group: [L1Element]) {}

  mutating func afterGroup(_ group: [L1Element]) {}

  mutating func walkText(_ text: String) {}

  mutating func visitText(_ text: Text) {}
}
