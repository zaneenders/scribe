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

extension Block {
  func optimizeTree() -> L2Element {
    self.toL1Element()
      .toL2Element()
  }
}

extension Block {
  /// Convert a ``Block`` structure into an Element structure. This is to
  /// simplify the tree structure in order to flatten the tree for more
  /// ergonomic movements over the tree.
  /// moves ArrayBlocks and TupleBlocks into the same group ``[Element]`` type.
  /// - Returns: A reshaped ``Block`` tree in the form of an Element tree.
  func toL1Element() -> L1Element {
    if let str = self as? String {
      return .text(str)
    } else if let text = self as? Text {
      return .text(text.text)
    } else if let actionBlock = self as? any ActionBlock {
      return .wrapped(
        actionBlock.component.toL1Element(), key: actionBlock.key, action: actionBlock.action)
    } else if let arrayBlock = self as? any ArrayBlocks {
      return makeGroup(from: arrayBlock._children)
    } else if let tupleArray = self as? any TupleBlocks {
      return makeGroup(from: tupleArray._children)
    } else {
      return .group([self.component.toL1Element()])
    }
  }

  private func makeGroup(from children: [any Block]) -> L1Element {
    var group: [L1Element] = []
    for child in children {
      group.append(child.toL1Element())
    }
    return .group(group)
  }
}
