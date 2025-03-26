@MainActor
/// Encapsulates the sate of the system. Primarily the block tree structure
/// and information about which block is selected.
struct BlockContainer: ~Copyable {
  private let block: any Block
  private var state = BlockState()

  init(_ block: consuming some Block) {
    self.block = block
    var l1Parser = InitialWalk(state: state, first: true)
    let l1tree = self.block.toL1Element()
    l1Parser.walk(l1tree)
    self.state = l1Parser.state
  }

  /// This is called
  /// - Parameter renderer: The renderer to draw the current state of the system with.
  func observe<R: Renderer>(with renderer: inout R) where R: ~Copyable {
    renderer.view(block, with: state)
  }

  /// Called to trigger a `.bind` function or a movement action.
  /// - Parameter code: the input received from the user.
  mutating func action(_ code: AsciiKeyCode) {
    switch code {
    case .lowercaseL:
      Log.debug("MoveIn")
      var move = MoveInWalker(state: state)
      move.walk(block.toL1Element())
      self.state = move.state
    case .lowercaseS:
      Log.debug("MoveOut")
      var move = MoveOutWalker(state: state)
      move.walk(block.toL1Element())
      self.state = move.state
    case .lowercaseJ:
      Log.debug("MoveDown")
      var move = MoveDownWalker(state: state)
      move.walk(block.toL1Element())
      self.state = move.state
    case .lowercaseF:
      Log.debug("MoveUp")
      var move = MoveUpWalker(state: state)
      move.walk(block.toL1Element())
      self.state = move.state
    default:
      if let char = String(bytes: [code.rawValue], encoding: .utf8) {
        Log.debug("input:\(char)")
        var action = ActionWalker(state: state, input: char)
        action.walk(block.toL1Element())
        self.state = action.state
      }
    }
  }
}
