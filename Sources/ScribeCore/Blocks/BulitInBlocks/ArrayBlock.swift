public struct ArrayBlock<B: Block>: Block, BuiltinBlock, ArrayBlocks {
    let type: BuiltinBlocks = .array
    let blocks: [B]

    var _blocks: [any Block] {
        blocks
    }
}

protocol ArrayBlocks {
    var _blocks: [any Block] { get }
}
