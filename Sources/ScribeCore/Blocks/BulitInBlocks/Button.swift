public struct Button: Block {
    public let label: String
    let action: () -> Void
    let type: BuiltinBlocks = .button
}

extension Button: BuiltinBlock {
    public init(_ label: String, _ action: @escaping () -> Void) {
        self.label = label
        self.action = action
    }
}
