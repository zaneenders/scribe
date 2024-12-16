import Foundation
import _NIOFileSystem

/// Define your environment
public protocol Scribe {
    init()
    var config: Config { get }
}

extension Scribe {
    mutating func run(_ view: inout Terminal) async throws {
        System.Log.trace("\(config.hello))")
        view.render(EntryView(config.hello))
        try await Task.sleep(for: .seconds(1))
        try await view.render(SystemView(FilePath(FileManager.default.currentDirectoryPath)))
        try await Task.sleep(for: .seconds(1))
    }
}

extension Scribe {
    public static func main() async {
        System.enableLogging(tracing: false, write_to_file: true)
        System.clearLog()
        var terminal = Terminal()
        var scribe = self.init()
        do {
            try await scribe.run(&terminal)
            terminal.goodbye()
        } catch {
            terminal.goodbye()
            print("Scribe ERROR: \(error.localizedDescription)")
        }
    }
}
