import _NIOFileSystem

struct SystemView: TerminalViewable {

    var dirs: [DirectoryEntry]
    var index = 0

    init(_ dir: FilePath) async throws {
        self.dirs = try await getDirectoryEntries(for: dir)
    }

    mutating func up() {
        if index - 1 >= 0 {
            index -= 1
        }
    }

    mutating func down() {
        if index + 1 < dirs.count {
            index += 1
        }
    }

    mutating func open() async throws {
        let entry: DirectoryEntry = dirs[index]
        switch entry.type {
        case .directory:
            self.dirs = try await getDirectoryEntries(for: entry.path)
            index = 0
        default:
            ()
        }
    }

    mutating func close() async throws {
        let new_path = dirs[index].path.removingLastComponent().removingLastComponent()
        System.Log.trace("\(#function)\(new_path.string)")
        self.dirs = try await getDirectoryEntries(for: new_path)
        index = 0
    }

    func tiles(_ width: Int, _ height: Int) -> [[Window.Tile]] {
        var out = Window(width, height, "#", .pink, .blue).tiles
        row_loop: for (y, entry) in dirs.enumerated() {
            if y >= height {
                break row_loop
            }
            char_loop: for (x, char) in entry.path.string.enumerated() {
                if x >= width {
                    break char_loop
                }
                if y == index {
                    out[y][x] = Window.Tile(symbol: char, fg: .white, bg: .teal)
                } else {
                    out[y][x] = Window.Tile(symbol: char, fg: .white, bg: .black)
                }
            }
        }
        System.Log.trace("\(#function)")
        return out
    }
}

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
