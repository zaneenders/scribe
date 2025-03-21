@MainActor
/// Encapsulates the sate of the system. Primarily the block tree structure
/// and information about which block is selected.
struct BlockContainer: ~Copyable {
  private let block: any Block
  private var state = BlockState()

  init(_ block: consuming some Block) {
    self.block = block
    var parser = InitialParser(state: state, first: true)
    parser.visit(self.block)
    self.state = parser.state
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
      var move = MoveInVisitor(state: state)
      move.visit(block)
      self.state = move.state
    case .lowercaseS:
      Log.debug("MoveOut")
      var move = MoveOutVisitor(state: state)
      move.visit(block)
      self.state = move.state
    case .lowercaseJ:
      Log.debug("MoveDown")
      var move = MoveDownVisitor(state: state)
      move.visit(block)
      self.state = move.state
    case .lowercaseF:
      Log.debug("MoveUp")
      var move = MoveUpVisitor(state: state)
      move.visit(block)
      self.state = move.state
    default:
      if let char = String(bytes: [code.rawValue], encoding: .utf8) {
        Log.debug("input:\(char)")
        var action = ActionVisitor(state: state, input: char)
        action.visit(block)
        self.state = action.state
      }
    }
  }
}
