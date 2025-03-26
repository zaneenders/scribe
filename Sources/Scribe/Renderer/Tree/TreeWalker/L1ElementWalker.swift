@MainActor
protocol L1ElementWalker {
  mutating func walkWrapped(_ element: L1Element, _ action: BlockAction?)
  mutating func walkText(_ text: String)
  mutating func walkGroup(_ group: [L1Element])
}

/*
NOTE: The following names are bad.
- visit
- _walk
*/
extension L1ElementWalker {
  mutating func walk(_ element: L1Element) {
    element.visit(&self)
  }
}

@MainActor
extension L1Element {
  fileprivate func visit(_ walker: inout some L1ElementWalker) {
    self._walk(&walker)
  }
}
