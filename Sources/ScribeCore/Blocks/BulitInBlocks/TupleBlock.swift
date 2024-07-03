public struct TupleBlock: Block, BuiltinBlock {
    private(set) var first: any Block
    private(set) var second: any Block
    let type: BuiltinBlocks = .tuple

    init<B0: Block, B1: Block>(first: B0, second: B1) {
        self.first = first
        self.second = second
    }
}
