protocol TerminalViewable: ~Copyable {
    func tiles(_ width: Int, _ height: Int) -> [[Window.Tile]]
}

extension Window {
    mutating func render<W: TerminalViewable>(_ viewable: borrowing W) where W: ~Copyable {
        System.Log.trace("\(#function): \(self.width), \(self.height)")
        self.tiles = viewable.tiles(self.width, self.height)
    }
}
