import Crypto

/// Parses the Block tree producing ``Hash``s based on the parent ``Block`` the
/// blocks position in the tree and the type of Block. Should remain
/// independent of the contains of the block IE it's mutations.
protocol L1HashWalker: L1ElementWalker {
  var currentHash: Hash { get set }
  mutating func beforeWrapped(_ element: L1Element, _ action: BlockAction?)
  mutating func afterWrapped(_ element: L1Element, _ action: BlockAction?)
  mutating func beforeGroup(_ group: [L1Element])
  mutating func afterGroup(_ group: [L1Element])
  mutating func beforeComposed(_ composed: L1Element)
  mutating func afterComposed(_ composed: L1Element)
}

extension L1HashWalker {
  mutating func walkWrapped(_ element: L1Element, _ action: BlockAction?) {
    beforeWrapped(element, action)
    let ourHash = currentHash
    currentHash = hash(contents: "\(ourHash)\(#function)")
    walk(element)
    currentHash = ourHash
    afterWrapped(element, action)
  }

  mutating func walkGroup(_ group: [L1Element]) {
    beforeGroup(group)
    let ourHash = currentHash
    for (index, element) in group.enumerated() {
      currentHash = hash(contents: "\(ourHash)\(#function)\(index)")
      walk(element)
    }
    currentHash = ourHash
    afterGroup(group)
  }

  mutating func walkComposed(_ composed: L1Element) {
    beforeComposed(composed)
    let ourHash = currentHash
    currentHash = hash(contents: "\(ourHash)\(#function)")
    walk(composed)
    currentHash = ourHash
    afterComposed(composed)
  }
}
