#if os(macOS)
import Darwin
import Foundation

/// Captures swift-log's console output and Chroma's print-based statistics.
enum AppConsoleLog {
  static func fileURL(home: URL, date: Date = Date()) -> URL {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = .current
    formatter.dateFormat = "yy-MM-dd"
    return home.appendingPathComponent("logs", isDirectory: true)
      .appendingPathComponent("remote-\(formatter.string(from: date)).log")
  }

  @discardableResult
  static func start() throws -> URL {
    let configured = ProcessInfo.processInfo.environment["SCRIBE_HOME"]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let home = URL(fileURLWithPath: NSString(
      string: configured.flatMap { $0.isEmpty ? nil : $0 } ?? "~/.scribe"
    ).expandingTildeInPath, isDirectory: true)
    let file = fileURL(home: home)
    try redirect(to: file)
    event("app.start log=\(file.path)")
    return file
  }

  static func event(_ message: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) [scribe.launch pid=\(getpid())] \(message)\n"
    try? FileHandle.standardError.write(contentsOf: Data(line.utf8))
  }

  static func redirect(to file: URL) throws {
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let fd = open(file.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(fd) }
    fflush(nil)
    guard dup2(fd, STDERR_FILENO) >= 0, dup2(fd, STDOUT_FILENO) >= 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    // Avoid fully buffered print output when launched from Finder.
    setvbuf(stdout, nil, _IONBF, 0)
  }
}
#endif
