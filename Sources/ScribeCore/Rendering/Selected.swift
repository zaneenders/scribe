extension SelectedStateNode: Equatable {
    static func == (lhs: SelectedStateNode, rhs: SelectedStateNode) -> Bool {
        switch (lhs, rhs) {
        case let (.button(l, _), .button(r, _)):
            return l == r  // this could be bad but really only using this for testing.
        case let (.text(tl), .text(tr)):
            return tl == tr
        case let (.selected(ln), .selected(rn)):
            return ln == rn
        case let (.textEntry(ls), .textEntry(rs)):
            return ls == rs
        case let (.group(lt, lo, lc), .group(rt, ro, rc)):
            let a = lt == rt
            let b = lo == ro
            let c = lc == rc
            return a && b && c
        default:
            return false
        }
    }
}

indirect enum SelectedStateNode {
    case button(String, () -> Void)
    case text(String)
    case textEntry(EntryStorage)
    case selected(SelectedStateNode)
    case group(GroupIndex, GroupOrientation, [SelectedStateNode])
}

extension GroupIndex: Equatable {}
enum GroupIndex {
    case entire
    case index(Int)
}

extension GroupIndex {
    var testDescription: String {
        switch self {
        case .entire:
            return ".entire"
        case let .index(i):
            return ".index(\(i))"
        }
    }
}

enum MoveInResponse {
    case normal
    case action
    case input
}

extension SelectedStateNode {
    var testDescription: String {
        switch self {
        case let .textEntry(s):
            return ".textEntry(\(s.testDescription))"
        case let .button(l, _):
            return ".button(\"\(l)\", {})"
        case let .text(t):
            return ".text(\"\(t)\")"
        case let .selected(node):
            return ".selected(\(node.testDescription))"
        case let .group(index, orientation, children):
            var group = ""
            for (i, child) in children.enumerated() {
                group += child.testDescription
                if i != children.count - 1 {
                    group += ","
                }
            }
            return
                ".group(\(index.testDescription),\(orientation.testDescription),[\(group)])"
        }
    }
}
