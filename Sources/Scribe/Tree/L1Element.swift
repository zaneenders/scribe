/// ``L1Element`` reduces the number of node types in a tree in order to be
/// flattened further.
indirect enum L1Element {
  case text(String)
  case wrapped(L1Element, key: String, action: BlockAction)
  case group([L1Element])
}

extension L1Element {
  func toL2Element() -> L2Element {
    switch self {
    case let .group(group):
      return .group(group.map { $0.toL2Element() }, nil)
    case let .text(text):
      return .text(text, nil)
    case let .wrapped(element, key, action):
      return .group([element.toL2Element()], L2Binding(key: key, action: action))
    }
  }
}
