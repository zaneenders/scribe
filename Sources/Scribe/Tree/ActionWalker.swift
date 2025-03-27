struct ActionWalker: L2HashWalker {

  private(set) var state: BlockState
  private var input: String
  var currentHash: Hash = hash(contents: "0")

  init(state: BlockState, input: String) {
    self.state = state
    self.input = input
  }

  mutating func beforeGroup(_ group: [L2Element], _ binding: L2Binding?) {
    Log.debug("\(#function): \(currentHash), \(state.selected)")
    runBinding(binding)
  }

  mutating func afterGroup(_ group: [L2Element], _ binding: L2Binding?) {}

  mutating func walkText(_ text: String, _ binding: L2Binding?) {
    Log.debug("\(#function): \(currentHash), \(state.selected)")
    runBinding(binding)
  }

  private func runBinding(_ binding: L2Binding?) {
    let selected = self.state.selected == currentHash
    if let binding {
      if selected && binding.key == input {
        binding.action()
      }
    }
  }
}
