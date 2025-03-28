/// Modified
public typealias InputHandler = (AsciiKeyCode) -> Void

extension String {
  @MainActor
  public func bind(handler: @escaping InputHandler) -> some Block {
    Input(wrapped: self, handler: handler)
  }
}

@MainActor
protocol InputBlock: Block {
  var handler: InputHandler { get }
  associatedtype Wrapped: Block
  var component: Wrapped { get }
}

struct Input<W: Block>: InputBlock {
  let wrapped: W
  let handler: InputHandler
  var component: some Block {
    wrapped.component
  }
}
