#if os(macOS)
import AppKit
import Darwin
import Chroma
import RemoteServer
import ScribeBlocks
import Foundation
import RemoteMetalClient

@main
struct ScribeMacApp {
  @MainActor
  static func main() throws {
    var arguments = Array(CommandLine.arguments.dropFirst())
    let backend = arguments.first == "--backend"
    if backend { arguments.removeFirst() }
    if arguments.contains("--help") || arguments.contains("-h") {
      print("usage: scribe-mac")
      print("Launches an owned local backend and the remote Metal display client.")
      return
    }
    guard arguments.isEmpty else {
      throw LaunchError.message("Unexpected arguments: \(arguments.joined(separator: " "))")
    }
    let windowSize = Size(width: 1100, height: 760)
    if backend {
      // Reserve stdout exclusively for readiness; normal logs stay in the terminal.
      let ready = FileHandle(fileDescriptor: dup(STDOUT_FILENO), closeOnDealloc: true)
      dup2(STDERR_FILENO, STDOUT_FILENO)
      let server = RemoteServer(content: ScribeBlock(), size: windowSize)
      server.frameObserver = ScribeSceneCapture.shared.enable()
      server.keyBindings = ScribeBlock.keyBindings
      try server.start(host: "127.0.0.1", port: 0)
      guard let port = server.boundPort else { throw LaunchError.message("No listening port") }
      try ready.write(contentsOf: Data("\(port)\n".utf8))
      try ready.close()
      // EOF also handles an abruptly killed parent, not just normal window closure.
      DispatchQueue.global().async {
        while !FileHandle.standardInput.availableData.isEmpty {}
        DispatchQueue.main.async {
          try? server.shutdown()
          exit(0)
        }
      }
      server.run()
      return
    }

    let owner = OwnedBackend()
    defer { owner.stop() }
    let port = try owner.start()
    let client = try RemoteMetalClient(size: windowSize, title: "Scribe")
    try client.connect(host: "127.0.0.1", port: port, framesPerSecond: 60)
    // AppKit terminate() does not unwind main(), so defer alone is insufficient.
    let observer = NotificationCenter.default.addObserver(
      forName: NSApplication.willTerminateNotification, object: nil, queue: .main
    ) { _ in owner.stop() }
    defer { NotificationCenter.default.removeObserver(observer) }
    owner.process.terminationHandler = { process in
      DispatchQueue.main.async {
        let alert = NSAlert()
        alert.messageText = "The local Scribe backend exited"
        alert.informativeText = "Backend exit status: \(process.terminationStatus). See the terminal for details."
        alert.runModal()
        NSApplication.shared.terminate(nil)
      }
    }
    // Detect an exit between the readiness handshake and installing the handler.
    guard owner.process.isRunning else { throw LaunchError.message("Backend exited during startup") }
    client.run()
  }
}

#endif
