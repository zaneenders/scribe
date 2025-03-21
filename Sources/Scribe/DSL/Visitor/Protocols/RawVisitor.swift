// TODO rename?
typealias Tuple = _TupleBlock

@MainActor
/// Raw Visitor where you are responsible for traversing into the next node but allows for alternative traversal patterns. See ``Visitor`` for a default implementation starting point.
protocol RawVisitor {
  /// visitText is consider the leaf node of any Block graph.
  mutating func visitText(_ text: Text)
  mutating func visitTuple<each Component: Block>(_ tuple: Tuple<repeat each Component>)
  mutating func visitEither<A: Block, B: Block>(_ either: _EitherBlock<A, B>)
  mutating func visitArray<B: Block>(_ array: _ArrayBlock<B>)
  mutating func visitModified<W: Block>(_ modified: Modified<W>)
  mutating func visitBlock(_ block: some Block)
}

extension RawVisitor {
  mutating func visit(_ block: some Block) {
    block.allow(&self)
  }
}

extension Block {

  // This kinda serves as the default visitor for now. I don't need to allow
  // custom stuff right now. We know all the types.
  fileprivate func allow(_ visitor: inout some RawVisitor) {
    if let visitableBlock = self as? any Visitable {
      visitableBlock._allow(&visitor)
    } else {
      visitor.visitBlock(self)
    }
  }
}
