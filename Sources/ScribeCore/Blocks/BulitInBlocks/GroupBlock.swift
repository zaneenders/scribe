public struct Group: Block, BuiltinBlock {
    let group: GroupOrientation
    var type: BuiltinBlocks {
        .group(group)
    }
    let wrapped: any Block
}

extension Group {
    public init(
        _ orientation: GroupOrientation, @BlockParser _ block: () -> some Block
    ) {
        self.group = orientation
        self.wrapped = block()
    }
}

extension GroupOrientation: Equatable, Codable {}
public enum GroupOrientation {
    case vertical
    case horizontal
}

extension GroupOrientation {
    var testDescription: String {
        switch self {
        case .horizontal:
            return ".horizontal"
        case .vertical:
            return ".vertical"
        }
    }
}
