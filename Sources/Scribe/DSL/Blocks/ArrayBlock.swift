/// The ``_ArrayBlock`` is the result of a `for <something> in <container>`.
public struct _ArrayBlock<Element: Block>: Block {
  let children: [Element]

  init(_ children: [Element]) {
    self.children = children
  }
}
