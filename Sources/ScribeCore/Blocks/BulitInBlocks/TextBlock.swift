struct Text: Block, BuiltinBlock {
    let text: String
    let type: BuiltinBlocks = .text
}

extension Text {
    init(_ text: String) {
        self.text = text
    }
}

/// Extends the String type to make writing declarative code easier and try to
/// require less type annotations.
extension String: Block {
    public var component: some Block {
        Text(self)
    }
}
