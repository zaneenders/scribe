indirect enum L1Node {
    case array(GroupOrientation, [L1Node])
    case button(String, () -> Void)
    case group(GroupOrientation, L1Node)
    case style
    case switchTo
    case text(String)
    case tuple(GroupOrientation, L1Node, L1Node)
    case composed(GroupOrientation, L1Node)
    case textEntry(EntryStorage)
}

extension Block {
    /// walks the Block tree and converts all nodes to there L1Node counter
    /// part. No information is lost here only created.
    func readBlockTree(_ orientation: GroupOrientation) -> L1Node {
        if let builtin = self as? any BuiltinBlock {
            switch builtin.type {
            case .textEntry:
                let t = builtin as! TextEntry
                return .textEntry(t.storage)
            case .array:
                let a = builtin as! any ArrayBlocks
                let l1Nodes: [L1Node] = a._blocks.map {
                    $0.readBlockTree(orientation)
                }
                return .array(orientation, l1Nodes)
            case .button:
                let b = builtin as! Button
                return .button(b.label, b.action)
            case let .group(gOrientation):
                let g = builtin as! Group
                return .group(
                    gOrientation, g.wrapped.readBlockTree(gOrientation))
            case .style:
                fatalError("Style not added yet")
            case .switchTo:
                fatalError("Switch to added yet")
            case .text:
                let t = builtin as! Text
                return .text(t.text)
            // TODO add Spacer()
            case .tuple:
                let t = builtin as! TupleBlock
                return .tuple(
                    orientation, t.first.readBlockTree(orientation),
                    t.second.readBlockTree(orientation))
            }
        } else {
            return .composed(
                orientation, self.component.readBlockTree(orientation))
        }
    }
}

extension L1Node {
    /// Walks the L1Node tree and flattens out L1Tuples and L1Composed Nodes as
    /// L2Arrays.
    func flattenTuplesAndComposed() -> L2Node {
        switch self {
        case let .textEntry(storage):
            return .textEntry(storage)
        case let .array(orientation, children):
            let l1Nodes: [L2Node] = children.map {
                $0.flattenTuplesAndComposed()
            }
            return .array(orientation, l1Nodes)
        case let .button(label, action):
            return .button(label, action)
        case let .group(orientation, node):
            return .group(orientation, node.flattenTuplesAndComposed())
        case .style:
            fatalError("Style not added yet")
        case .switchTo:
            fatalError("Switch to added yet")
        case let .text(text):
            return .text(text)
        case let .composed(orientation, node):
            return .array(
                orientation, [node.flattenTuplesAndComposed()])
        case let .tuple(orientation, first, second):
            return .array(
                orientation,
                [
                    first.flattenTuplesAndComposed(),
                    second.flattenTuplesAndComposed(),
                ])

        }
    }
}
