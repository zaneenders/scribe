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
    var readTask: Task<Void, Never>?
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
  private let descriptorLock = NSLock()
  // A PTY is one byte stream. Keep each logical write contiguous even when
  // callers (and, eventually, daemon clients) submit input concurrently.
  private let writeLock = NSLock()
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
    let nonblockingResult = scribe_set_nonblocking(master, 1)
    guard nonblockingResult == 0 else {
      _ = systemClose(master)
      _ = systemKill(pid, SIGHUP)
      var status: Int32 = 0
      while waitpid(pid, &status, 0) == -1, errno == EINTR {}
      throw PTYSessionError.operationFailed(nonblockingResult)
    }

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
    try writeLock.withLock {
      let fd = try duplicateFileDescriptor()
      defer { _ = systemClose(fd) }
      let blockingResult = scribe_set_nonblocking(fd, 0)
      guard blockingResult == 0 else { throw PTYSessionError.operationFailed(blockingResult) }

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
  }

  /// Writes the terminal's interrupt control byte. The PTY line discipline sends
  /// SIGINT to its foreground process group, exactly like a native terminal.
  public func interrupt() throws { try write(Data([0x03])) }

  public func resize(columns: UInt16, rows: UInt16) throws {
    let fd = try duplicateFileDescriptor()
    defer { _ = systemClose(fd) }
    let result = scribe_pty_resize(fd, Int32(columns), Int32(rows))
    if result != 0 { throw PTYSessionError.operationFailed(result) }
  }

  // Duplicate while holding the state lock so cancellation cannot close and
  // recycle the master descriptor between validation and dup(2). The duplicate
  // keeps the PTY open for the complete operation without serializing writes.
  private func duplicateFileDescriptor() throws -> Int32 {
    try descriptorLock.withLock {
      try state.withLock { state in
        guard !state.isClosing, !state.readEnded else { throw PTYSessionError.closed }
        var duplicate: Int32 = -1
        let result = scribe_dup_cloexec(state.masterFD, &duplicate)
        guard result == 0 else { throw PTYSessionError.operationFailed(result) }
        return duplicate
      }
    }
  }

  public func close() {
    // Use the same lock order as duplicateFileDescriptor(). The reader holds
    // descriptorLock only around a bounded poll and a nonblocking read, so this
    // closes the master promptly without racing descriptor reuse.
    let task = descriptorLock.withLock {
      state.withLock { state -> Task<Void, Never>? in
        guard !state.isClosing else { return nil }
        state.isClosing = true
        state.readEnded = true
        let task = state.readTask
        state.readTask = nil
        let fd = state.masterFD
        state.masterFD = -1

        // Keep the transition and signal atomic with respect to the waiter.
        // Before waitStatus is recorded, waitid(WNOWAIT) guarantees this PID is
        // either the live child or its unreaped zombie; afterwards we do not signal.
        if state.waitStatus == nil, childPID > 0 { _ = systemKill(childPID, SIGHUP) }
        if fd >= 0 { _ = systemClose(fd) }
        return task
      }
    }
    task?.cancel()
    deliverExitIfReady()
  }

  private func startReading(fileDescriptor: Int32) {
    let task = Task.detached(priority: .high) { [weak self, descriptorLock] in
      while !Task.isCancelled {
        // Poll without the descriptor lock so close() never waits for the timeout.
        // Before reading, revalidate under the lock that close() has not invalidated
        // the descriptor; this also prevents reading from a recycled descriptor.
        var descriptor = pollfd(fd: fileDescriptor, events: Int16(POLLIN), revents: 0)
        let pollResult = poll(&descriptor, 1, 100)
        if pollResult == 0 { continue }
        if pollResult == -1 {
          if errno == EINTR { continue }
          break
        }

        guard let self else { return }
        let result: (count: Int, data: Data?, error: Int32) = descriptorLock.withLock {
          let isOpen = state.withLock {
            !$0.isClosing && $0.masterFD == fileDescriptor
          }
          guard isOpen else { return (0, nil, 0) }

          var buffer = [UInt8](repeating: 0, count: 64 * 1024)
          let count = systemRead(fileDescriptor, &buffer, buffer.count)
          return (count, count > 0 ? Data(buffer.prefix(count)) : nil, errno)
        }

        if result.count == 0 { break }
        if result.count == -1 {
          if result.error == EINTR || result.error == EAGAIN { continue }
          break
        }
        if let data = result.data { deliverOutput(data) }
      }

      self?.finishReading()
    }
    state.withLock { $0.readTask = task }
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

  private func finishReading() {
    let didFinish = state.withLock { state -> Bool in
      guard !state.readEnded else { return false }
      state.readEnded = true
      state.readTask = nil
      return true
    }
    if didFinish { deliverExitIfReady() }
  }

  private func startWaiting() {
    let pid = childPID
    DispatchQueue.global(qos: .utility).async { [weak self] in
      // Observe exit without reaping first. While the child remains a zombie its
      // PID cannot be reused, so close() can safely decide whether SIGHUP still
      // targets this process while recording the transition under state.
      let waitResult = scribe_wait_until_exited(pid)
      guard waitResult == 0 else { return }
      var status: Int32 = 0
      guard let self else {
        while waitpid(pid, &status, 0) == -1, errno == EINTR {}
        return
      }
      let reaped = self.state.withLock { state -> Bool in
        while waitpid(pid, &status, 0) == -1 {
          if errno != EINTR { return false }
        }
        state.waitStatus = status
        return true
      }
      if reaped { self.deliverExitIfReady() }
    }
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
