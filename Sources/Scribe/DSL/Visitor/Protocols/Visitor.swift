/// Helper function for traversing the tree and providing optional hooks before
/// and after child nodes.
protocol Visitor: RawVisitor {
  mutating func beforeTuple<each Component: Block>(_ tuple: _TupleBlock<repeat each Component>)
  mutating func afterTuple<each Component: Block>(_ tuple: _TupleBlock<repeat each Component>)

  mutating func beforeEither<A: Block, B: Block>(_ either: _EitherBlock<A, B>)
  mutating func afterEither<A: Block, B: Block>(_ either: _EitherBlock<A, B>)

  mutating func beforeArray<B: Block>(_ array: _ArrayBlock<B>)
  mutating func afterArray<B: Block>(_ array: _ArrayBlock<B>)

  mutating func beforeModified<W: Block>(_ modified: Modified<W>)
  mutating func afterModified<W: Block>(_ modified: Modified<W>)

  mutating func beforeBlock(_ block: some Block)
  mutating func afterBlock(_ block: some Block)
}

extension Visitor {

  mutating func beforeTuple<each Component: Block>(_ tuple: _TupleBlock<repeat each Component>) {}
  mutating func afterTuple<each Component: Block>(_ tuple: _TupleBlock<repeat each Component>) {}

  mutating func beforeEither<A: Block, B: Block>(_ either: _EitherBlock<A, B>) {}
  mutating func afterEither<A: Block, B: Block>(_ either: _EitherBlock<A, B>) {}

  mutating func beforeArray<B: Block>(_ array: _ArrayBlock<B>) {}
  mutating func afterArray<B: Block>(_ array: _ArrayBlock<B>) {}

  mutating func beforeModified<W: Block>(_ modified: Modified<W>) {}
  mutating func afterModified<W: Block>(_ modified: Modified<W>) {}

  mutating func beforeBlock(_ block: some Block) {}
  mutating func afterBlock(_ block: some Block) {}
}

extension Visitor {

  mutating func visitTuple<each Component: Block>(_ tuple: _TupleBlock<repeat each Component>) {
    beforeTuple(tuple)
    for child in repeat (each tuple.children) {
      visit(child)
    }
    afterTuple(tuple)
  }

  mutating func visitEither<A: Block, B: Block>(_ either: _EitherBlock<A, B>) {
    beforeEither(either)
    switch either.either {
    case let .first(first):
      visit(first)
    case let .second(second):
      visit(second)
    }
    afterEither(either)
  }

  mutating func visitArray<B: Block>(_ array: _ArrayBlock<B>) {
    beforeArray(array)
    for child in array.children {
      visit(child)
    }
    afterArray(array)
  }

  mutating func visitModified<W: Block>(_ modified: Modified<W>) {
    beforeModified(modified)
    visit(modified.wrapped)
    afterModified(modified)
  }

  mutating func visitBlock(_ block: some Block) {
    beforeBlock(block)
    visit(block.component)
    afterBlock(block)
  }
}
