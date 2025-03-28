enum L2Element {
  case text(String, L2Binding?)
  case group([L2Element])
}

struct L2Binding {
  let key: String
  let action: BlockAction
}

extension L2Element {
  /// Flattens groups of like orientation into one layer to make navigation
  /// easier.
  /// - Returns:
  func flatten() -> L2Element {
    switch self {
    case let .group(group):
      var children: [L2Element] = []
      for child in group.map { $0.flatten() } {
        switch child {
        case let .group(grandChildren):
          children += grandChildren.map { $0.flatten() }
        case .text:
          children.append(child)
        }
      }
      return .group(children)
    case .text:
      return self
    }
  }
}
