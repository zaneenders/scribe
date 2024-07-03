indirect enum L2Node {
    case array(GroupOrientation, [L2Node])
    case button(String, () -> Void)
    case group(GroupOrientation, L2Node)
    case style
    case switchTo
    case text(String)
    case textEntry(EntryStorage)
}

extension L2Node {

    func mergeArraysIntoGroups() -> L3Node {
        switch self {
        case let .textEntry(storage):
            return .textEntry(storage)
        case let .array(orientation, children):
            let children = children.map { $0.mergeArraysIntoGroups() }
            return .group(orientation, children)
        case let .button(label, action):
            return .button(label, action)
        case let .group(orientation, node):
            return .group(orientation, [node.mergeArraysIntoGroups()])
        case .style:
            fatalError("Style not added yet")
        case .switchTo:
            fatalError("Switch not added yet")
        case let .text(text):
            return .text(text)
        }
    }
}
