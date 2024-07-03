public indirect enum VisibleNode: Codable {
    // NOTE Maybe replace with .style rendering doesn't care whats selected
    // just what and where things go
    case selected(VisibleNode)
    case button(String)
    case entry(String)
    case group(GroupOrientation, [VisibleNode])
    // case style(VisibleNode)
    case text(String)
}

extension VisibleNode {
    var minX: Int {
        switch self {
        case let .entry(l):
            return l.count
        case let .button(l):
            return l.count
        case let .text(t):
            return t.count
        case let .group(o, children):
            var x = 0
            for c in children {
                switch o {
                case .vertical:
                    x += c.minX
                case .horizontal:
                    x = max(x, c.minX)
                }
            }
            return x
        case let .selected(child):
            return child.minX
        }
    }

    var minY: Int {
        switch self {
        case .button, .text, .entry:
            return 1
        case let .group(o, children):
            var y = 0
            for c in children {
                switch o {
                case .vertical:
                    y = max(y, c.minY)
                case .horizontal:
                    y += c.minY
                }
            }
            return y
        case let .selected(child):
            return child.minY
        }
    }
}
