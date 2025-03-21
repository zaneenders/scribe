/// Used when a block is optionally available.
public struct _EitherBlock<First: Block, Second: Block>: Block {

  enum Either {
    case first(First)
    case second(Second)
  }

  let either: Either

  init(_ either: Either) {
    self.either = either
  }
}
