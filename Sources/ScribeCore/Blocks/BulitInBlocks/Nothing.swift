struct Nothing: Block, BuiltinBlock {
    var type: BuiltinBlocks {
        fatalError("Nothing is not a block type")
    }
}
