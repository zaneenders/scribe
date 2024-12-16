import Foundation
import _NIOFileSystem

/// Define your environment
public protocol Scribe {
    init()
    var config: Config { get }
}

extension Scribe {
    public static func main() async {
        let scribe = self.init()
        print(scribe.config.hello)
        var currenDir = FilePath(FileManager.default.currentDirectoryPath)
        do {
            for path in try await getDirectoryEntries(for: currenDir) {
                print(path.path.string)
            }
        } catch {
            print("Scribe ERROR: \(error.localizedDescription)")
        }
    }
}

func getDirectoryEntries(for dir: FilePath) async throws -> [DirectoryEntry] {
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
