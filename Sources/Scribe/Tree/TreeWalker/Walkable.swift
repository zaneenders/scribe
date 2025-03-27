/// Protocol to require blocks to implement a function that passes them self
/// into the Visitor function.
@MainActor
protocol L2Walkable {
  func _walk(_ walker: inout some L2ElementWalker)
}

extension L2Element: L2Walkable {
  func _walk(_ walker: inout some L2ElementWalker) {
    switch self {
    case let .group(group, binding):
      walker.walkGroup(group, binding)
    case let .text(text, binding):
      walker.walkText(text, binding)
    }
  }
}
