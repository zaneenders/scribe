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
    var controlFD: Int32
    var statusFD: Int32
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
  private let exitGroup = DispatchGroup()
  // A PTY is one byte stream. Keep each logical write contiguous even when
  // callers (and, eventually, daemon clients) submit input concurrently.
  private let writeLock = NSLock()
  // The supervisor is our direct child and is always reaped. The terminal
  // leader owns an isolated process group containing the shell and descendants.
  private let supervisorPID: pid_t
  private let processGroupPID: pid_t

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
    var supervisor: pid_t = -1
    var processGroup: pid_t = -1
    var control: Int32 = -1
    var statusFD: Int32 = -1
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
              &supervisor,
              &processGroup,
              &control,
              &statusFD
            )
          }
        }
      }
    }
    guard result == 0 else { throw PTYSessionError.spawnFailed(result) }
    let nonblockingResult = scribe_set_nonblocking(master, 1)
    guard nonblockingResult == 0 else {
      _ = systemClose(control)
      _ = systemClose(statusFD)
      _ = systemClose(master)
      var status: Int32 = 0
      while waitpid(supervisor, &status, 0) == -1, errno == EINTR {}
      throw PTYSessionError.operationFailed(nonblockingResult)
    }

    supervisorPID = supervisor
    processGroupPID = processGroup
    state = Mutex(State(masterFD: master, controlFD: control, statusFD: statusFD))
    startReading(fileDescriptor: master)
    startWaiting()
  }

  deinit {
    close()
    // A process owner must not disappear before its direct child is reaped.
    // The supervisor uses SIGKILL on control-pipe EOF, so this wait is bounded
    // by scheduler latency and keeps zombies out of a long-lived daemon.
    exitGroup.wait()
  }

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
        let controlFD = state.controlFD
        state.controlFD = -1

        // Closing the control descriptor also triggers cleanup if the daemon
        // crashes. Signal explicitly here for prompt graceful teardown; the
        // supervisor escalates to SIGKILL and waits for the session leader.
        if state.waitStatus == nil, processGroupPID > 2 {
          _ = systemKill(-processGroupPID, SIGHUP)
        }
        // EOF is the close request. Avoid writing because the supervisor may
        // already have closed its read end, which would raise process-fatal SIGPIPE.
        if controlFD >= 0 { _ = systemClose(controlFD) }
        if fd >= 0 { _ = systemClose(fd) }
        return task
      }
    }
    task?.cancel()
    exitGroup.wait()
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
    let pid = supervisorPID
    let statusDescriptor = state.withLock { $0.statusFD }
    exitGroup.enter()
    DispatchQueue.global(qos: .utility).async { [weak self, exitGroup] in
      // The supervisor cannot encode a signal termination through its own exit
      // code, so it sends the leader's unmodified waitpid status over this pipe.
      var leaderStatus: Int32 = 0
      var received = 0
      withUnsafeMutableBytes(of: &leaderStatus) { bytes in
        while received < bytes.count {
          let count = systemRead(statusDescriptor, bytes.baseAddress!.advanced(by: received), bytes.count - received)
          if count > 0 {
            received += count
          } else if count == -1 && errno == EINTR {
            continue
          } else {
            break
          }
        }
      }
      _ = systemClose(statusDescriptor)

      var supervisorStatus: Int32 = 0
      var result: pid_t
      repeat {
        result = waitpid(pid, &supervisorStatus, 0)
      } while result == -1 && errno == EINTR
      // Mark reaping complete before invoking user callbacks. An exit callback
      // is allowed to reenter close(), which waits on this group.
      exitGroup.leave()
      guard result == pid, received == MemoryLayout<Int32>.size, let self else { return }
      self.state.withLock { state in
        state.waitStatus = leaderStatus
        state.statusFD = -1
        if state.controlFD >= 0 {
          _ = systemClose(state.controlFD)
          state.controlFD = -1
        }
      }
      self.deliverExitIfReady()
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
