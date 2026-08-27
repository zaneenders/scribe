#if canImport(Darwin)
import Darwin
private let systemWrite = Darwin.write
private let systemRead = Darwin.read
private let systemClose = Darwin.close
private let systemKill = Darwin.kill
#elseif canImport(Glibc)
import Glibc
private let systemWrite = Glibc.write
private let systemRead = Glibc.read
private let systemClose = Glibc.close
private let systemKill = Glibc.kill
#endif

#if canImport(Darwin) || canImport(Glibc)
import Dispatch
import Foundation
import PTYShim

public enum PTYSessionError: Error, CustomStringConvertible {
  case spawnFailed(Int32)

  public var description: String {
    switch self {
    case .spawnFailed(let code):
      return String(cString: strerror(code))
    }
  }
}

/// A long-lived shell attached to a pseudo-terminal.
public final class PTYSession: @unchecked Sendable {
  private let lock = NSLock()
  private var outputHandler: (@Sendable (Data) -> Void)?
  private var exitHandler: (@Sendable (Int32) -> Void)?
  private var pendingOutput = Data()
  private var pendingExitStatus: Int32?

  public var onOutput: (@Sendable (Data) -> Void)? {
    get { lock.withLock { outputHandler } }
    set {
      let pending = lock.withLock { () -> Data in
        outputHandler = newValue
        defer { pendingOutput.removeAll(keepingCapacity: false) }
        return pendingOutput
      }
      if !pending.isEmpty { newValue?(pending) }
    }
  }

  public var onExit: (@Sendable (Int32) -> Void)? {
    get { lock.withLock { exitHandler } }
    set {
      let status = lock.withLock { () -> Int32? in
        exitHandler = newValue
        defer { pendingExitStatus = nil }
        return pendingExitStatus
      }
      if let status { newValue?(status) }
    }
  }

  private var masterFD: Int32
  private var childPID: pid_t
  private var readSource: DispatchSourceRead?
  private var closed = false

  public init(
    shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/sh",
    workingDirectory: String = FileManager.default.currentDirectoryPath,
    columns: UInt16 = 80,
    rows: UInt16 = 24
  ) throws {
    var environment = ProcessInfo.processInfo.environment
    environment["TERM"] = "xterm-256color"
    environment["COLORTERM"] = "truecolor"
    environment.removeValue(forKey: "SWIFTLY_PROXY_IN_PROGRESS")

    var master: Int32 = -1
    var pid: pid_t = -1
    let arguments = [shell, "-l"]
    let result = Self.withCStringArray(arguments) { argv in
      Self.withCStringArray(environment.map { "\($0.key)=\($0.value)" }) { envp in
        shell.withCString { shellPointer in
          workingDirectory.withCString { directoryPointer in
            scribe_pty_spawn(
              shellPointer,
              argv,
              envp,
              directoryPointer,
              Int32(columns),
              Int32(rows),
              &master,
              &pid
            )
          }
        }
      }
    }
    guard result == 0 else { throw PTYSessionError.spawnFailed(result) }

    masterFD = master
    childPID = pid
    startReading()
    startWaiting()
  }

  deinit { close() }

  public func write(_ string: String) {
    write(Data(string.utf8))
  }

  public func write(_ data: Data) {
    guard !data.isEmpty else { return }
    lock.lock()
    let fd = closed ? -1 : masterFD
    lock.unlock()
    guard fd >= 0 else { return }

    data.withUnsafeBytes { bytes in
      guard var pointer = bytes.baseAddress else { return }
      var remaining = bytes.count
      while remaining > 0 {
        let count = systemWrite(fd, pointer, remaining)
        if count > 0 {
          pointer = pointer.advanced(by: count)
          remaining -= count
        } else if count == -1 && errno == EINTR {
          continue
        } else {
          break
        }
      }
    }
  }

  /// Writes the terminal's interrupt control byte. The PTY line discipline sends
  /// SIGINT to its foreground process group, exactly like a native terminal.
  public func interrupt() { write(Data([0x03])) }

  public func resize(columns: UInt16, rows: UInt16) {
    lock.lock()
    let fd = closed ? -1 : masterFD
    lock.unlock()
    if fd >= 0 {
      _ = scribe_pty_resize(fd, Int32(columns), Int32(rows))
    }
  }

  public func close() {
    lock.lock()
    guard !closed else {
      lock.unlock()
      return
    }
    closed = true
    let fd = masterFD
    let pid = childPID
    masterFD = -1
    readSource?.cancel()
    readSource = nil
    lock.unlock()

    _ = systemClose(fd)
    if pid > 0 { _ = systemKill(pid, SIGHUP) }
  }

  private func startReading() {
    let source = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: .global(qos: .userInitiated))
    source.setEventHandler { [weak self] in
      guard let self else { return }
      let available = max(1, min(Int(source.data), 64 * 1024))
      var buffer = [UInt8](repeating: 0, count: available)
      let count = systemRead(masterFD, &buffer, buffer.count)
      if count > 0 {
        let data = Data(buffer.prefix(count))
        let handler = lock.withLock { () -> (@Sendable (Data) -> Void)? in
          guard let outputHandler else {
            pendingOutput.append(data)
            return nil
          }
          return outputHandler
        }
        handler?(data)
      } else if count == 0 || (errno != EINTR && errno != EAGAIN) {
        source.cancel()
      }
    }
    readSource = source
    source.resume()
  }

  private func startWaiting() {
    let pid = childPID
    DispatchQueue.global(qos: .utility).async { [weak self] in
      guard let self else { return }
      var status: Int32 = 0
      _ = waitpid(pid, &status, 0)
      let handler = lock.withLock { () -> (@Sendable (Int32) -> Void)? in
        guard let exitHandler else {
          pendingExitStatus = status
          return nil
        }
        return exitHandler
      }
      handler?(status)
      close()
    }
  }

  private static func withCStringArray<Result>(
    _ strings: [String],
    _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> Result
  ) rethrows -> Result {
    let pointers = strings.map { strdup($0) }
    defer { pointers.forEach { free($0) } }
    var terminated = pointers + [nil]
    return try terminated.withUnsafeMutableBufferPointer { buffer in
      try body(buffer.baseAddress!)
    }
  }
}
#endif
