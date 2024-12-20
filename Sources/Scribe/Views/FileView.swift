import _NIOFileSystem

/*
Very unfinished.
- [X] display viewable part of file.
- [ ] File Scrolling
    - Maybe we can reuse logic for ``SystemView`` as well.
- [ ] Edit file
- [ ] write changes to disk
*/
struct FileView: TerminalViewable, Program {

    var contents: String

    init(_ path: FilePath) async throws {
        let fh = try await FileSystem.shared.openFile(
            forReadingAndWritingAt: path, options: .modifyFile(createIfNecessary: true))
        let info = try await fh.info()
        let buffer = try await fh.readToEnd(maximumSizeAllowed: .bytes(info.size))
        self.contents = String(buffer: buffer)
        try await fh.close()
    }

    mutating func down(_ num: Int) {

    }

    mutating func up(_ num: Int) {

    }

    mutating func open() async throws -> OpenResult {
        .dir
    }

    mutating func close() async throws {

    }

    func tiles(_ width: Int, _ height: Int) -> [[Window.Tile]] {
        // TODO change default window.
        var tiles = Window(width, height, "$", .green, .purple).tiles
        let splits = contents.split(maxSplits: height, omittingEmptySubsequences: false) { $0 == "\n" }
        System.Log.notice("splits: \(splits.count)")
        outer_loop: for (y, split) in splits.enumerated() {
            if y >= height {
                continue outer_loop
            }
            inner_loop: for (x, char) in split.enumerated() {
                if char == "\n" {
                    System.Log.error("NEWLINE: \(x) \(y)")
                }
                if x < width {
                    tiles[y][x] = Window.Tile(char)
                } else {
                    continue inner_loop
                }
            }
        }
        System.Log.notice("tiles: \(tiles.count) \(tiles[0].count)")
        return tiles
    }
}
