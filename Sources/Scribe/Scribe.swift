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
        var system_view = try await SystemView(FilePath(FileManager.default.currentDirectoryPath))
        for try await byte in FileDescriptor.standardInput.asyncByteIterator() {
            let code = AsciiKeyCode.decode(keyboard: byte)
            switch code {
            case .ctrlC:
                return
            case .lowerCaseF:
                system_view.up()
            case .lowerCaseJ:
                system_view.down()
            case .lowerCaseL:  // Enter
                try await system_view.open()
            case .lowerCaseS:
                try await system_view.close()
            default:
                ()
            }
            view.render(system_view)
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
        var terminal: Terminal!
        do {
            terminal = try Terminal()
        } catch {
            System.Log.error("Unable to correctly setup terminal.")
            return
        }
        do {
            try await scribe.run(&terminal)
        } catch {
            System.Log.error("Scribe ERROR: \(error.localizedDescription)")
        }
    }
}
