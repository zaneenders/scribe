import Crypto

/// Parses the Block tree producing ``Hash``s based on the parent ``Block`` the
/// blocks position in the tree and the type of Block. Should remain
/// independent of the contains of the block IE it's mutations.
protocol HashVisitor: Visitor {
  var currentHash: Hash { get set }
}

extension HashVisitor {

  mutating func visitTuple<each Component: Block>(_ tuple: _TupleBlock<repeat each Component>) {
    let ourHash = currentHash
    beforeTuple(tuple)
    var index = 0
    for child in repeat (each tuple.children) {
      currentHash = hash(contents: "\(ourHash)\(#function)\(index)")
      visit(child)
      index += 1
    }
    currentHash = ourHash
    afterTuple(tuple)
  }

  mutating func visitArray<B: Block>(_ array: _ArrayBlock<B>) {
    let ourHash = currentHash
    beforeArray(array)
    for (index, child) in array.children.enumerated() {
      currentHash = hash(contents: "\(ourHash)\(#function)\(index)")
      visit(child)
    }
    currentHash = ourHash
    afterArray(array)
  }

  mutating func visitModified<W: Block>(_ modified: Modified<W>) {
    let ourHash = currentHash
    beforeModified(modified)
    currentHash = hash(contents: "\(ourHash)\(#function)")
    visit(modified.wrapped)
    currentHash = ourHash
    afterModified(modified)
  }

  mutating func visitBlock(_ block: some Block) {
    let ourHash = currentHash
    beforeBlock(block)
    currentHash = hash(contents: "\(ourHash)\(#function)")
    visit(block.component)
    currentHash = ourHash
    afterBlock(block)
  }
}

func hash(contents: String) -> Hash {
  var copy = contents
  var sha = Insecure.SHA1()
  copy.withUTF8 {
    sha.update(data: $0)
  }
  let f = sha.finalize()
  return f.description.replacingOccurrences(of: "SHA1 digest: ", with: "")
}
