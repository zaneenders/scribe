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
    var diagnosticPath = "the original stderr output (file logging unavailable)"
    if !backend {
      do {
        diagnosticPath = try AppConsoleLog.start().path
      } catch {
        AppConsoleLog.event("log.open.failed error=\(error)")
      }
    }
    do {
      try run(backend: backend, diagnosticPath: diagnosticPath)
    } catch {
      AppConsoleLog.event("startup.failed role=\(backend ? "backend" : "client") error=\(error)")
      throw error
    }
  }

  @MainActor
  private static func run(backend: Bool, diagnosticPath: String) throws {
    let windowSize = Size(width: 1100, height: 760)
    if backend {
      // Keep the readiness pipe separate from inherited diagnostic output.
      let ready = FileHandle(fileDescriptor: dup(STDOUT_FILENO), closeOnDealloc: true)
      dup2(STDERR_FILENO, STDOUT_FILENO)
      setvbuf(stdout, nil, _IONBF, 0)
      AppConsoleLog.event("backend.start")
      let server = RemoteServer(content: ScribeBlock(), size: windowSize)
      server.frameObserver = ScribeSceneCapture.shared.enable()
      server.keyBindings = ScribeBlock.keyBindings
      try server.start(host: "127.0.0.1", port: 0)
      guard let port = server.boundPort else { throw LaunchError.message("No listening port") }
      try ready.write(contentsOf: Data("\(port)\n".utf8))
      try ready.close()
      AppConsoleLog.event("backend.ready host=127.0.0.1 port=\(port)")
      // EOF also handles an abruptly killed parent, not just normal window closure.
      DispatchQueue.global().async {
        while !FileHandle.standardInput.availableData.isEmpty {}
        DispatchQueue.main.async {
          AppConsoleLog.event("backend.shutdown reason=parent-control-closed")
          try? server.shutdown()
          exit(0)
        }
      }
      server.run()
      return
    }

    let owner = OwnedBackend()
    defer {
      owner.stop()
      AppConsoleLog.event("app.run.returned")
    }
    AppConsoleLog.event("backend.launch")
    let port = try owner.start()
    AppConsoleLog.event("backend.connected pid=\(owner.process.processIdentifier) port=\(port)")
    let client = try RemoteMetalClient(size: windowSize, title: "Scribe")
    try client.connect(host: "127.0.0.1", port: port, framesPerSecond: 60)
    AppConsoleLog.event("client.connected host=127.0.0.1 port=\(port) requested_fps=60")
    // AppKit terminate() does not unwind main(), so defer alone is insufficient.
    let observer = NotificationCenter.default.addObserver(
      forName: NSApplication.willTerminateNotification, object: nil, queue: .main
    ) { _ in
      AppConsoleLog.event("app.terminate")
      owner.stop()
    }
    defer { NotificationCenter.default.removeObserver(observer) }
    owner.process.terminationHandler = { process in
      AppConsoleLog.event("backend.exited status=\(process.terminationStatus) reason=\(process.terminationReason)")
      DispatchQueue.main.async {
        let alert = NSAlert()
        alert.messageText = "The local Scribe backend exited"
        alert.informativeText = "Backend exit status: \(process.terminationStatus). Diagnostics: \(diagnosticPath)"
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
