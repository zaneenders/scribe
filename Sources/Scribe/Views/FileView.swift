/*
Very unfinished.
- [ ] display viewable part of file.
- [ ] write changes to disk
- [ ] File Scrolling
    - Maybe we can reuse logic for ``SystemView`` as well.
*/
struct FileView: TerminalViewable, Program {
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
        Window(width, height, "$", .green, .purple).tiles
    }
}
