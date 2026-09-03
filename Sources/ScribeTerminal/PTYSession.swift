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
import Synchronization

public enum PTYSessionError: Error, CustomStringConvertible {
  case spawnFailed(Int32)
  case closed
  case operationFailed(Int32)

  public var description: String {
    switch self {
    case .spawnFailed(let code), .operationFailed(let code):
      return String(cString: strerror(code))
    case .closed:
      return "PTY session is closed"
    }
  }
}

/// A long-lived shell attached to a pseudo-terminal.
public final class PTYSession: Sendable {
  private struct State {
    var outputHandler: (@Sendable (Data) -> Void)?
    var exitHandler: (@Sendable (Int32) -> Void)?
    var pendingOutput = Data()
    var isDeliveringOutput = false
    var pendingExitStatus: Int32?
    var masterFD: Int32
    var readSource: DispatchSourceRead?
    var isClosing = false
    var readEnded = false
    var waitStatus: Int32?
    var exitDelivered = false
  }

  private struct ExitDelivery {
    let handler: @Sendable (Int32) -> Void
    let status: Int32
  }

  private let state: Mutex<State>
  private let childPID: pid_t

  public var onOutput: (@Sendable (Data) -> Void)? {
    get { state.withLock { $0.outputHandler } }
    set {
      let shouldDrain = state.withLock { state in
        state.outputHandler = newValue
        return beginOutputDeliveryIfNeeded(&state)
      }
      if shouldDrain { drainPendingOutput() }
    }
  }

  public var onExit: (@Sendable (Int32) -> Void)? {
    get { state.withLock { $0.exitHandler } }
    set {
      let status = state.withLock { state -> Int32? in
        state.exitHandler = newValue
        defer { state.pendingExitStatus = nil }
        return state.pendingExitStatus
      }
      if let status { newValue?(status) }
    }
  }

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

    childPID = pid
    state = Mutex(State(masterFD: master))
    startReading(fileDescriptor: master)
    startWaiting()
  }

  deinit { close() }

  public func write(_ string: String) throws {
    try write(Data(string.utf8))
  }

  public func write(_ data: Data) throws {
    guard !data.isEmpty else { return }
    let fd = try openFileDescriptor()

    try data.withUnsafeBytes { bytes in
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
          throw PTYSessionError.operationFailed(errno)
        }
      }
    }
  }

  /// Writes the terminal's interrupt control byte. The PTY line discipline sends
  /// SIGINT to its foreground process group, exactly like a native terminal.
  public func interrupt() throws { try write(Data([0x03])) }

  public func resize(columns: UInt16, rows: UInt16) throws {
    let fd = try openFileDescriptor()
    let result = scribe_pty_resize(fd, Int32(columns), Int32(rows))
    if result != 0 { throw PTYSessionError.operationFailed(result) }
  }

  private func openFileDescriptor() throws -> Int32 {
    try state.withLock { state in
      guard !state.isClosing, !state.readEnded else { throw PTYSessionError.closed }
      return state.masterFD
    }
  }

  public func close() {
    let source = state.withLock { state -> DispatchSourceRead? in
      guard !state.isClosing else { return nil }
      state.isClosing = true
      state.readEnded = true
      let source = state.readSource
      state.readSource = nil
      return source
    }
    source?.cancel()
    if childPID > 0 { _ = systemKill(childPID, SIGHUP) }
    deliverExitIfReady()
  }

  private func startReading(fileDescriptor: Int32) {
    let source = DispatchSource.makeReadSource(
      fileDescriptor: fileDescriptor, queue: .global(qos: .userInitiated))
    source.setEventHandler { [weak self, weak source] in
      guard let self, let source else { return }
      let available = max(1, min(Int(source.data), 64 * 1024))
      var buffer = [UInt8](repeating: 0, count: available)
      let count = systemRead(fileDescriptor, &buffer, buffer.count)
      if count > 0 {
        deliverOutput(Data(buffer.prefix(count)))
      } else if count == 0 || (errno != EINTR && errno != EAGAIN) {
        finishReading(source)
      }
    }
    source.setCancelHandler {
      _ = systemClose(fileDescriptor)
    }
    state.withLock { $0.readSource = source }
    source.resume()
  }

  private func deliverOutput(_ data: Data) {
    let handler = state.withLock { state -> (@Sendable (Data) -> Void)? in
      guard !state.readEnded else { return nil }
      guard !state.isDeliveringOutput, let handler = state.outputHandler else {
        state.pendingOutput.append(data)
        return nil
      }
      state.isDeliveringOutput = true
      return handler
    }
    guard let handler else { return }
    handler(data)
    drainPendingOutput()
  }

  private func beginOutputDeliveryIfNeeded(_ state: inout State) -> Bool {
    guard !state.isDeliveringOutput, state.outputHandler != nil, !state.pendingOutput.isEmpty else {
      return false
    }
    state.isDeliveringOutput = true
    return true
  }

  private func drainPendingOutput() {
    while true {
      let delivery = state.withLock { state -> ((@Sendable (Data) -> Void), Data)? in
        guard let handler = state.outputHandler, !state.pendingOutput.isEmpty else {
          state.isDeliveringOutput = false
          return nil
        }
        let data = state.pendingOutput
        state.pendingOutput.removeAll(keepingCapacity: false)
        return (handler, data)
      }
      guard let (handler, data) = delivery else {
        deliverExitIfReady()
        return
      }
      handler(data)
    }
  }

  private func finishReading(_ source: DispatchSourceRead) {
    let shouldCancel = state.withLock { state -> Bool in
      guard !state.readEnded else { return false }
      state.readEnded = true
      state.readSource = nil
      return true
    }
    if shouldCancel { source.cancel() }
    deliverExitIfReady()
  }

  private func startWaiting() {
    let pid = childPID
    DispatchQueue.global(qos: .utility).async { [weak self] in
      var status: Int32 = 0
      while waitpid(pid, &status, 0) == -1, errno == EINTR {}
      self?.recordWaitStatus(status)
    }
  }

  private func recordWaitStatus(_ status: Int32) {
    state.withLock { $0.waitStatus = status }
    deliverExitIfReady()
  }

  private func deliverExitIfReady() {
    let delivery = state.withLock { state -> ExitDelivery? in
      guard
        state.readEnded,
        !state.isDeliveringOutput,
        state.pendingOutput.isEmpty,
        let status = state.waitStatus,
        !state.exitDelivered
      else { return nil }
      state.exitDelivered = true
      guard let handler = state.exitHandler else {
        state.pendingExitStatus = status
        return nil
      }
      return ExitDelivery(handler: handler, status: status)
    }
    if let delivery { delivery.handler(delivery.status) }
  }

  private static func withCStringArray<Result>(
    _ strings: [String],
    _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> Result
  ) rethrows -> Result {
    let pointers = strings.map { strdup($0) }
    defer {
      for pointer in pointers { free(pointer) }
    }
    var terminated = pointers + [nil]
    return try terminated.withUnsafeMutableBufferPointer { buffer in
      try body(buffer.baseAddress!)
    }
  }
}
#endif
