protocol BuiltinBlock {
    var type: BuiltinBlocks { get }
}

enum BuiltinBlocks {
    case style
    case group(GroupOrientation)
    case array
    case button
    case text
    case tuple
    case switchTo
    case textEntry
}

extension BuiltinBlock {
    public var component: some Block {
        return Nothing()
    }
}
