import ArgumentParser
import Foundation
import Logging
import ScribeCore

struct _ScribeEditCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "_edit",
    abstract: "Experimental scratch buffer editor.",
    discussion: "Underscore prefix = internal/testing surface."
  )

  func run() async throws {
    let editDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("scribe-edit", isDirectory: true)
    try? FileManager.default.createDirectory(at: editDir, withIntermediateDirectories: true)

    let logFile = editDir.appendingPathComponent("\(UUID().uuidString).log")
    _ = FileManager.default.createFile(atPath: logFile.path, contents: nil)
    guard let handle = try? FileHandle(forUpdating: logFile) else {
      throw ScribeError.generic("Failed to open log file: \(logFile.path)")
    }
    _ = try? handle.seekToEnd()

    let log = Logger(label: "scribe._edit") { _ in
      ScribeLineLogHandler(
        minimumLevel: .debug,
        dataWriter: LockedDataWriter { data in
          try? handle.write(contentsOf: data)
        })
    }
    print("logging to \(logFile.path)")
    try await SlateEditHost.runFullscreen(log: log)
  }
}
