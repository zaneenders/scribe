#if os(macOS)
import Darwin
import Foundation
import Synchronization

enum LaunchError: Error, CustomStringConvertible {
  case message(String)
  var description: String {
    switch self {
    case .message(let text): text
    }
  }
}

/// Only this launcher owns this process. The display client never owns an external server.
final class OwnedBackend: Sendable {
  let process = Process()
  private let control = Pipe()
  private let readiness = Pipe()
  private let stopped = Mutex(false)

  func start() throws -> Int {
    try start(executableURL: Self.executableURL(), arguments: ["--backend"])
  }

  private static func executableURL() throws -> URL {
    var size: UInt32 = 0
    _ = _NSGetExecutablePath(nil, &size)
    var path = [CChar](repeating: 0, count: Int(size))
    guard _NSGetExecutablePath(&path, &size) == 0 else {
      throw LaunchError.message("Cannot locate the Scribe executable")
    }
    return URL(
      fileURLWithPath: String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    ).resolvingSymlinksInPath()
  }

  /// Injectable child command and deadlines keep lifecycle tests independent of GPU/AppKit.
  func start(executableURL: URL, arguments: [String], timeout: TimeInterval = 15) throws -> Int {
    process.executableURL = executableURL
    process.arguments = arguments
    process.standardInput = control
    process.standardOutput = readiness
    process.standardError = FileHandle.standardError
    try process.run()
    try control.fileHandleForReading.close()
    try readiness.fileHandleForWriting.close()

    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    var data = Data()
    while ProcessInfo.processInfo.systemUptime < deadline {
      var descriptor = pollfd(fd: readiness.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
      let result = poll(&descriptor, 1, 100)
      if result < 0 {
        if errno == EINTR { continue }
        throw LaunchError.message("Failed reading backend readiness")
      }
      if result == 0 { continue }
      guard let byte = try readiness.fileHandleForReading.read(upToCount: 1), !byte.isEmpty else {
        throw LaunchError.message("Backend exited before becoming ready")
      }
      if byte == Data([10]) {
        guard let text = String(data: data, encoding: .utf8), let port = Int(text), (1...65535).contains(port) else {
          throw LaunchError.message("Invalid backend readiness response")
        }
        return port
      }
      data.append(byte)
      guard data.count <= 5 else { throw LaunchError.message("Invalid backend readiness response") }
    }
    throw LaunchError.message("Backend startup timed out after \(timeout) seconds")
  }

  func stop() {
    stopped.withLock { stopped in
      guard !stopped else { return }
      stopped = true
      process.terminationHandler = nil
      try? control.fileHandleForWriting.close()
      try? readiness.fileHandleForReading.close()
      guard process.processIdentifier > 0 else { return }
      let deadline = ProcessInfo.processInfo.systemUptime + 2
      while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
        Thread.sleep(forTimeInterval: 0.01)
      }
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
      process.waitUntilExit()
    }
  }
}
#endif
