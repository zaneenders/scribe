/// Modified
public typealias BlockAction = () -> Void

extension Block {
  /// Bind a key to this ``Block`` allowing interaction and emulate the
  /// conventional button.
  /// - Parameters:
  ///   - key: The input key to be matched on.
  ///   - action: The block of code to execute when the block is selected and
  /// the key is pressed
  /// - Returns: A wrapper around the block containing the information needed
  /// to execute the code.
  public func bind(key: String, action: @escaping BlockAction) -> some Block {
    // TODO update key to be a type to handle ctrl and shift combinations.
    Modified(wrapped: self, key: key, action: action)
  }
}

struct Modified<W: Block>: Block, ActionBlock {
  let type: ActionType = .modified
  let wrapped: W
  let key: String
  let action: BlockAction
  var component: some Block {
    wrapped.component
  }
}

@MainActor
protocol ActionBlock {
  var type: ActionType { get }
  var action: BlockAction { get }
  associatedtype Wrapped: Block
  var component: Wrapped { get }
}

enum ActionType {
  case modified
  case text
}
