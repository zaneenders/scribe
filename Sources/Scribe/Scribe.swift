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
    mutating func start(_ view: inout Terminal) async throws {
        System.Log.trace("\(config.hello)")

        view.render(EntryView(config.hello))
        var current_program: any Program & TerminalViewable = try await SystemView(
            FilePath(FileManager.default.currentDirectoryPath))
        /*
        I think we want some sort of program stack or something here to switch between.
        We have a system view but that can trigger state changes to the file_view or something?
        */
        var stack: [() async throws -> SystemView] = []
        for try await byte in FileDescriptor.standardInput.asyncByteIterator() {
            let key = AsciiKeyCode.decode(keyboard: byte)
            /*
            Kind think I should have some sort of keyboard mapping preferences here,
            but I think that makes it to hard right now
            */
            switch key {
            case .ctrlC:
                if current_program is FileView {  // Close file
                    System.Log.notice("Closing file.")
                    let system_view = stack.removeFirst()
                    // This should never throw unless the directory doesn't exist anymore?
                    current_program = try await system_view()
                } else {
                    return
                }
            case .lowerCaseF:
                current_program.up()
            case .lowerCaseJ:
                current_program.down()
            case .lowerCaseL:
                switch try await current_program.open() {
                case .dir:
                    ()
                case let .file(cwd: cwd, file: file):
                    System.Log.notice("Opening File: \(file.string)")
                    stack.append({
                        try await SystemView(cwd)
                    })
                    current_program = try await FileView(file)
                }
            case .lowerCaseS:
                try await current_program.close()
            default:
                ()
            }
            view.render(current_program)
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
            try await scribe.start(&terminal)
        } catch {
            System.Log.error("Scribe ERROR: \(error.localizedDescription)")
        }
    }
}
