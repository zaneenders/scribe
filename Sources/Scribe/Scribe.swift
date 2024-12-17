import Foundation
import SystemPackage
import _NIOFileSystem

public typealias Command = () async throws -> Void

/// Define your environment
public protocol Scribe {
    init()
    var config: Config { get }
    var commands: [String: Command] { get }
}

extension Scribe {
    mutating func run(_ view: inout Terminal) async throws {
        System.Log.trace("\(config.hello))")
        view.render(EntryView(config.hello))
        try await Task.sleep(for: .seconds(1))
        for try await byte in FileDescriptor.standardInput.asyncByteIterator() {
            if byte == 3 {
                return
            }
            try await view.render(SystemView(FilePath(FileManager.default.currentDirectoryPath)))
        }
    }
}

extension Scribe {
    public static func main() async {
        var scribe = self.init()
        if CommandLine.arguments.count > 1 {
            if let command = scribe.commands[CommandLine.arguments[1].lowercased()] {
                do {
                    try await command()
                } catch {
                    print(error.localizedDescription)
                }
                return
            }
        }
        // Allow commands to setup there own logging setup.
        System.enableLogging(tracing: false, write_to_file: true)
        System.clearLog()
        var terminal = Terminal()
        do {
            try await scribe.run(&terminal)
            terminal.goodbye()
        } catch {
            terminal.goodbye()
            print("Scribe ERROR: \(error.localizedDescription)")
        }
    }
}
