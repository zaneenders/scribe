import _NIOFileSystem

private func getDirectoryEntries(for dir: FilePath) async throws -> [DirectoryEntry] {
    var paths: [DirectoryEntry] = []
    let dir = try await FileSystem.shared.openDirectory(atPath: dir)
    let entries = dir.listContents()
    var i = entries.makeAsyncIterator()
    var next = try await i.next()
    repeat {
        if let n = next {
            paths.append(n)
        }
        next = try await i.next()
    } while next != nil
    try await dir.close()
    return paths
}

struct SystemView: TerminalViewable {
    let dirs: [DirectoryEntry]
    init(_ dir: FilePath) async throws {
        self.dirs = try await getDirectoryEntries(for: dir)
    }

    func tiles(_ width: Int, _ height: Int) -> [[Window.Tile]] {
        var out = Window(width, height, "#", .pink, .blue).tiles
        row_loop: for (y, entry) in dirs.enumerated() {
            if y > height {
                break row_loop
            }
            char_loop: for (x, char) in entry.path.string.enumerated() {
                if x > width {
                    break char_loop
                }
                out[y][x] = Window.Tile(symbol: char, fg: .white, bg: .black)
            }
        }
        return out
    }
}
