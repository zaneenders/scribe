/// The ``Block`` protocol is used to compose your own custom blocks. You can build up more complex Blocks using String literals and the ``bind(key:action:)`` function to add
/// interactivity.
@MainActor  // This is required to force ``Block``s to be processed on the main thread allowing for other actions to be performed on other threads/actors.
public protocol Block {
  associatedtype Component: Block
  @BlockParser var component: Component { get }
}

extension Block where Component == Never {
  public var component: Never {
    fatalError("\(Self.self):\(#fileID):\(#function)")
  }
}

extension Never: Block {
  public var component: some Block {
    fatalError("\(Self.self):\(#fileID):\(#function)")
  }
}
