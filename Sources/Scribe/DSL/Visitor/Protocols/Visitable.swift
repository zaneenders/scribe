@MainActor
/// Protocol to require blocks to implement a function that passes them self
/// into the Visitor function.
protocol Visitable {
  func _allow(_ visitor: inout some RawVisitor)
}

/// Example of _allow being implemented to allow the ``Visitor`` to call
/// `.visitText` implemented by the caller
extension Text: Visitable {
  func _allow(_ visitor: inout some RawVisitor) {
    visitor.visitText(self)
  }
}

extension _TupleBlock: Visitable {
  func _allow(_ visitor: inout some RawVisitor) {
    visitor.visitTuple(self)
  }
}

extension _ArrayBlock: Visitable {
  func _allow(_ visitor: inout some RawVisitor) {
    visitor.visitArray(self)
  }
}

extension Modified: Visitable {
  func _allow(_ visitor: inout some RawVisitor) {
    visitor.visitModified(self)
  }
}
