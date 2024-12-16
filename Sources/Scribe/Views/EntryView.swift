struct EntryView: TerminalViewable {
    private let hello: String
    init(_ hello: String) {
        self.hello = hello
    }
    func tiles(_ width: Int, _ height: Int) -> [[Window.Tile]] {
        var out = Window(width, height, "#", .pink, .blue).tiles
        for (i, char) in hello.enumerated() {
            if i < width {
                out[0][i] = Window.Tile(symbol: char, fg: .white, bg: .black)
            }
        }
        return out
    }
}
