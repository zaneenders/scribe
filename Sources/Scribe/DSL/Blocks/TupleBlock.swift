/// Composed of N many child ``Block``s.
public struct _TupleBlock<each Component: Block>: Block {
  let children: (repeat each Component)

  init(_ child: repeat each Component) {
    self.children = (repeat each child)
  }
}
