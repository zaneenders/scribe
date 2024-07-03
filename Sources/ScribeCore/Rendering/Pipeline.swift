/// The pipeline used to display the graph and apply user interaction updates.
extension Block {
    func pipeline(_ path: SelectedStateNode?, _ x: Int, _ y: Int) -> (
        SelectedStateNode, VisibleNode
    ) {
        var pathCopy = path
        let visible = self.readBlockTree(.vertical)
            .flattenTuplesAndComposed()
            .mergeArraysIntoGroups()
            .wrapWithGroup()
            .flattenSimilarGroups()
            .createPath()
            .mergeState(with: &pathCopy)
            .computeVisible(x, y)
        return (pathCopy!, visible)
    }
}

extension SelectedStateNode {
    /// applies the given command to the current selected state node.
    /// Not sure if this is right or not honestly. But current approach isn't
    /// great. At least this would be a pure function. thought I think I will
    /// end up passing a lot of information up and down this call stack. Maybe
    /// CPS?
    func apply(command: Command) -> (SelectedStateNode, Mode) {
        switch command {
        case let .unsafeInput(input):
            // Not sure what to do with the bool saying input was added or not.
            let (s, _) = applyUnsafe(input: input)
            return (s, .input)
        case .in:
            let (s, a) = applyMoveIn()
            switch a {
            case .normal:
                return (s, .normal)
            case .action:
                s.press()
                return (s, .normal)
            case .input:
                return (s, .input)
            }
        case .out:
            return (applyMoveOut(youAreRoot: true).0, .normal)
        case .up:
            return (applyMoveUp(), .normal)
        case .down:
            return (applyMoveDown(), .normal)
        case .left:
            return (applyMoveLeft(), .normal)
        case .right:
            return (applyMoveRight(), .normal)
        }
    }

    private func press(_ youAreSelected: Bool = false) {
        switch self {
        case .textEntry:
            return  // TODO enter entry state
        case .text(_):
            return
        case let .button(_, action):
            if youAreSelected {
                action()
            }
        case let .selected(node):
            node.press(true)
        case let .group(_, _, children):
            children.forEach { $0.press() }
        }
    }

    private func applyUnsafe(input: String)
        -> (SelectedStateNode, Bool)
    {
        switch self {
        case let .textEntry(storage):
            storage.text += input
            return (self, true)
        case .text, .button:
            // Leaf Nodes
            return (self, false)
        case let .selected(node):
            // removes the selected
            let (n, r) = node.applyUnsafe(input: input)
            return (.selected(n), r)
        case let .group(type, orientation, children):
            switch type {
            case .entire:
                // parent wasn't selected so we aren't being moved into.
                return (self, false)
            case let .index(i):
                // selection is in our ith child
                var copy = children
                let (r, s) = children[i].applyUnsafe(input: input)
                copy[i] = r
                return (.group(.index(i), orientation, copy), s)
            }
        }
    }

    private func applyMoveOut(youAreRoot: Bool = false) -> (
        SelectedStateNode, Bool?
    ) {
        switch self {
        case .textEntry(_):
            return (self, nil)
        case .text(_):
            return (self, nil)
        case .button(_, _):
            return (self, nil)
        case let .selected(node):
            if youAreRoot {
                // the what the bool is here doesn't really matter.
                return (self, false)
            }
            // removes the selected
            let (n, r) = node.applyMoveOut()
            switch r {
            case .some(true):
                // Double Selected
                fatalError("Double selected \(#function)")
            case .some(false), .none:
                ()  // Do nothing child was either a leaf node or group
            }
            return (n, true)
        case let .group(type, orientation, children):
            switch type {
            case let .index(i):  // selected path
                var copy = children
                let (n, r) = children[i].applyMoveOut()
                copy[i] = n
                switch r {
                case .some(true):
                    // Child was selected we should be selected now
                    return (
                        .selected(.group(.entire, orientation, copy)), false
                    )
                case .some(false), .none:
                    // Child was a leaf node or selected was below us.
                    return (.group(.index(i), orientation, copy), false)
                }
            case .entire:
                // .entire can't have a selected node below it so just return as normal
                return (self, false)
            }
        }
    }

    enum InputResponse {
        case action
        case input
        case normal
    }

    private func applyMoveIn(_ youWereSelected: Bool = false)
        -> (SelectedStateNode, InputResponse)
    {
        switch self {
        case .textEntry:
            if youWereSelected {
                return (.selected(self), .input)
            } else {
                return (self, .normal)
            }
        case .text, .button:
            // Leaf Nodes
            if youWereSelected {
                return (.selected(self), .action)
            } else {
                return (self, .normal)
            }
        case let .selected(node):
            // removes the selected
            return node.applyMoveIn(true)
        case let .group(type, orientation, children):
            if youWereSelected {
                var copy = children
                copy[0] = .selected(children[0])
                return (.group(.index(0), orientation, copy), .normal)
            } else {
                switch type {
                case .entire:
                    // parent wasn't selected so we aren't being moved into.
                    return (self, .normal)
                case let .index(i):
                    // selection is in our ith child
                    var copy = children
                    let (r, s) = children[i].applyMoveIn()
                    copy[i] = r
                    return (.group(.index(i), orientation, copy), s)
                }
            }
        }
    }

    private func applyMoveDown(_ youWereSelected: Bool = false)
        -> SelectedStateNode
    {
        switch self {
        case .textEntry(_):
            return self
        case .text(_):
            return self
        case .button(_, _):
            return self
        case let .selected(node):
            // removes .selected
            return node.applyMoveDown(true)
        case let .group(type, orientation, children):
            switch type {
            case let .index(i):  // selected path
                switch orientation {
                case .vertical:
                    guard i >= 0 && i < children.count - 1 else {
                        return self
                    }
                    var copy = children
                    let n = children[i].applyMoveDown()
                    copy[i] = n
                    copy[i + 1] = .selected(children[i + 1])
                    return .group(.index(i + 1), .vertical, copy)
                case .horizontal:
                    if youWereSelected {
                        return self
                    } else {
                        var copy = children
                        let n = children[i].applyMoveDown()
                        copy[i] = n
                        return .group(.index(i), .horizontal, copy)
                    }
                }
            case .entire:
                // .entire can't have a selected node below it so just return as normal
                if youWereSelected {
                    return .selected(self)
                } else {
                    return self
                }
            }
        }
    }

    private func applyMoveUp(_ youWereSelected: Bool = false)
        -> SelectedStateNode
    {
        switch self {
        case .textEntry(_):
            return self
        case .text(_):
            return self
        case .button(_, _):
            return self
        case let .selected(node):
            // removes .selected
            return node.applyMoveUp(true)
        case let .group(type, orientation, children):
            switch type {
            case let .index(i):  // selected path
                switch orientation {
                case .vertical:
                    guard i >= 1 && i < children.count else {
                        return self
                    }
                    var copy = children
                    let n = children[i].applyMoveUp()
                    copy[i] = n
                    copy[i - 1] = .selected(children[i - 1])
                    return .group(.index(i - 1), .vertical, copy)
                case .horizontal:
                    if youWereSelected {
                        return self
                    } else {
                        var copy = children
                        let n = children[i].applyMoveUp()
                        copy[i] = n
                        return .group(.index(i), .horizontal, copy)
                    }
                }
            case .entire:
                // .entire can't have a selected node below it so just return as normal
                if youWereSelected {
                    return .selected(self)
                } else {
                    return self
                }
            }
        }
    }

    private func applyMoveRight(_ youWereSelected: Bool = false)
        -> SelectedStateNode
    {
        switch self {
        case .textEntry(_):
            return self
        case .text(_):
            return self
        case .button(_, _):
            return self
        case let .selected(node):
            // removes .selected
            return node.applyMoveRight(true)
        case let .group(type, orientation, children):
            switch type {
            case let .index(i):  // selected path
                switch orientation {
                case .horizontal:
                    guard i >= 0 && i < children.count - 1 else {
                        return self
                    }
                    var copy = children
                    let n = children[i].applyMoveRight()
                    copy[i] = n
                    copy[i + 1] = .selected(children[i + 1])
                    return .group(.index(i + 1), .horizontal, copy)
                case .vertical:
                    if youWereSelected {
                        return self
                    } else {
                        var copy = children
                        let n = children[i].applyMoveUp()
                        copy[i] = n
                        return .group(.index(i), .vertical, copy)
                    }
                }
            case .entire:
                // .entire can't have a selected node below it so just return as normal
                if youWereSelected {
                    return .selected(self)
                } else {
                    return self
                }
            }
        }
    }

    private func applyMoveLeft(_ youWereSelected: Bool = false)
        -> SelectedStateNode
    {
        switch self {
        case .textEntry(_):
            return self
        case .text(_):
            return self
        case .button(_, _):
            return self
        case let .selected(node):
            // removes .selected
            return node.applyMoveLeft(true)
        case let .group(type, orientation, children):
            switch type {
            case let .index(i):  // selected path
                switch orientation {
                case .horizontal:
                    guard i >= 1 && i < children.count else {
                        return self
                    }
                    var copy = children
                    let n = children[i].applyMoveUp()
                    copy[i] = n
                    copy[i - 1] = .selected(children[i - 1])
                    return .group(.index(i - 1), .horizontal, copy)
                case .vertical:
                    if youWereSelected {
                        return self
                    } else {
                        var copy = children
                        let n = children[i].applyMoveUp()
                        copy[i] = n
                        return .group(.index(i), .vertical, copy)
                    }
                }
            case .entire:
                // .entire can't have a selected node below it so just return as normal
                if youWereSelected {
                    return .selected(self)
                } else {
                    return self
                }
            }
        }
    }
}

extension SelectedStateNode {
    /// This will return the minium need space for the sub parts well
    /// displaying as many nodes as possible that fit within the width and
    /// height
    // TODO should VisibleNode be optional in that we don't consume it?
    func computeVisible(_ width: Int, _ height: Int)
        -> VisibleNode
    {
        switch self {
        case let .textEntry(s):
            return .entry(s.text)
        case let .group(_, orientation, children):
            // Do I need the index or anything else?
            var xt = 0
            var yt = 0
            var nodes: [VisibleNode] = []
            for child in children {
                let n: VisibleNode
                switch orientation {
                case .horizontal:
                    let v = child.computeVisible(width - xt, height)
                    n = v
                    // the group is as wide as it's largest element.
                    yt = max(yt, v.minY)
                    xt += v.minX
                case .vertical:
                    let v = child.computeVisible(width, height - yt)
                    n = v
                    yt += v.minY
                    // the group is as tall as it's largest element.
                    xt = max(xt, v.minX)
                }
                // TODO check if we should append based on if we have enough room
                nodes.append(n)
            }
            return .group(orientation, nodes)
        case let .selected(child):
            return .selected(child.computeVisible(width, height))
        case let .text(t):
            return .text(t)
        case let .button(l, _):
            return .button(l)
        }
    }
}

/// Merges the lhs tree with the rhs tree. The rhs side holds the selection
/// state so favor rhs for selection. Other wise lhs is source of truth and
/// gets updates from user input.
private func merge(lhs: SelectedStateNode, rhs: SelectedStateNode)
    -> SelectedStateNode
{
    // Favor right side as it as the selected states
    switch (lhs, rhs) {
    case let (.button(l, la), .button(_, _)):
        return .button(l, la)
    case let (.text(l), .text(_)):
        return .text(l)
    case let (.selected(lNode), .selected(rNode)):
        return .selected(merge(lhs: lNode, rhs: rNode))
    case let (.textEntry(_), .textEntry(rs)):
        return .textEntry(rs)  // correct state is in rhs
    case let (.group(_, _, lc), .group(rt, ro, rc)):
        var children: [SelectedStateNode] = []
        for (lc, rc) in zip(lc, rc) {
            children.append(merge(lhs: lc, rhs: rc))
        }
        return .group(rt, ro, children)
    case let (lNode, .selected(rNode)):
        return .selected(merge(lhs: lNode, rhs: rNode))
    default:
        fatalError("\(#function)[\(lhs):\(rhs)]")  // Invalid tree
    }
}

extension SelectedStateNode {

    func mergeState(with prev: inout SelectedStateNode?) -> SelectedStateNode {
        if let path = prev {
            let r = merge(lhs: self, rhs: path)
            prev = r
            return r
        } else {
            // Should really only be called 1st pass.
            let pathWrappedWithSelected = self.makeFirstPath()
            prev = pathWrappedWithSelected
            return pathWrappedWithSelected
        }
    }

    private func makeFirstPath() -> SelectedStateNode {
        switch self {
        case let .textEntry(s):
            return .selected(.textEntry(s))
        case let .button(l, a):
            return .selected(.button(l, a))
        case let .text(t):
            return .selected(.text(t))
        case .selected:
            fatalError("Double Selected")
        case let .group(index, orientation, children):
            return .selected(.group(index, orientation, children))
        }
    }
}
