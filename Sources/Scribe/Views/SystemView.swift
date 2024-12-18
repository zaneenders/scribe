import Algorithms
import _NIOFileSystem

struct SystemView: TerminalViewable {

    var index = 0
    private var _dirs: [DirectoryEntry]
    var dirs: [DirectoryEntry] {
        get {
            _dirs.sorted(by: { $0.path.string < $1.path.string })
        }
        set {
            _dirs = newValue
        }
    }

    init(_ dir: FilePath) async throws {
        self._dirs = try await getDirectoryEntries(for: dir)
    }

    mutating func up(_ num: Int = 1) {
        if index - num >= 0 {
            index -= num
        }
    }

    mutating func down(_ num: Int = 1) {
        if index + num < dirs.count {
            index += num
        }
    }

    mutating func open() async throws {
        let entry: DirectoryEntry = dirs[index]
        switch entry.type {
        case .directory:
            self._dirs = try await getDirectoryEntries(for: entry.path)
            index = 0
        default:
            ()
        }
    }

    mutating func close() async throws {
        let new_path = dirs[index].path.removingLastComponent().removingLastComponent()
        System.Log.trace("\(#function)\(new_path.string)")
        self._dirs = try await getDirectoryEntries(for: new_path)
        index = 0
    }

    func getDirsInRange(_ height: Int) -> [DirectoryEntry] {
        // TODO still kinda broken but it moves for now
        /*
        - [ ] Movement is doubled
        - [ ] Last window is kinda broken
        */
        let windows = dirs.windows(ofCount: height)
        for (i, window) in windows.enumerated() {
            if i >= index {
                return Array(window)
            }
        }
        // Not sure what to return here yet...
        return dirs
    }

    func tiles(_ width: Int, _ height: Int) -> [[Window.Tile]] {
        var out = Window(width, height, "#", .pink, .blue).tiles
        row_loop: for (y, entry) in getDirsInRange(height).enumerated() {
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
