/// Uses the ``HashVisitor`` to parse the AST and when it hits a ``Modified``
/// ``Block`` it calls the binded function if that block is selected.
struct ActionVisitor: HashVisitor {
  private(set) var state: BlockState
  private var input: String
  var currentHash: Hash = hash(contents: "0")

  init(state: BlockState, input: String) {
    self.state = state
    self.input = input
  }

  mutating func visitText(_ text: Text) {}

  mutating func beforeModified<W>(_ modified: Modified<W>) where W: Block {
    Log.debug("\(#function): \(currentHash), \(state.selected)")
    let selected = self.state.selected == currentHash
    if selected && modified.key == input {
      modified.action()
    }
  }
}
