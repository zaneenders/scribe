@MainActor
/// Protocol to require blocks to implement a function that passes them self
/// into the Visitor function.
protocol Walkable {
  func _walk(_ walker: inout some L1ElementWalker)
}

extension L1Element: Walkable {
  func _walk(_ walker: inout some L1ElementWalker) {
    switch self {
    case let .group(group):
      walker.walkGroup(group)
    case let .text(text):
      walker.walkText(text)
    case let .wrapped(element, action):
      walker.walkWrapped(element, action)
    }
  }
}
