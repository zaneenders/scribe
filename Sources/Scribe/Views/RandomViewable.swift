/// A test viewable that can be used for debugging ``TerminalViewable``
internal struct RandomViewable: TerminalViewable {
    func tiles(_ width: Int, _ height: Int) -> [[Window.Tile]] {
        let chars: [Character] = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        var new = Window(width, height).tiles
        for y in 0..<height {
            for x in 0..<width {
                let r = Int.random(in: 0..<chars.count)
                new[y][x] = Window.Tile(
                    symbol: chars[r],
                    fg: Chroma.Color.random(),
                    bg: Chroma.Color.random())
            }
        }
        return new
    }
}

extension Chroma.Color {
    static func random() -> Chroma.Color {
        let colors = Self.allCases
        let r = Int.random(in: 0..<colors.count)
        for (i, color) in colors.enumerated() {
            if i == r {
                return color
            }
        }
        return .default
    }
}
