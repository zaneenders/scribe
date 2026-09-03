import DequeModule
import Foundation
import Synchronization

/// Stable identity for a terminal owned by a ``TerminalRuntime``.
public struct TerminalID: Hashable, Sendable, Codable {
  public let rawValue: UUID

  public init(rawValue: UUID = UUID()) {
    self.rawValue = rawValue
  }
}

public struct TerminalSize: Equatable, Sendable, Codable {
  public var columns: UInt16
  public var rows: UInt16

  public init(columns: UInt16 = 80, rows: UInt16 = 24) {
    self.columns = max(1, columns)
    self.rows = max(1, rows)
  }
}

public struct TerminalConfiguration: Equatable, Sendable {
  public var shell: String
  public var workingDirectory: String
  public var size: TerminalSize

  public init(
    shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/sh",
    workingDirectory: String = FileManager.default.currentDirectoryPath,
    size: TerminalSize = TerminalSize()
  ) {
    self.shell = shell
    self.workingDirectory = workingDirectory
    self.size = size
  }
}

/// A range of terminal output. Cursors are byte offsets, so an attachment can
/// resume after `endCursor` without knowing how the runtime chunked the bytes.
public struct TerminalOutput: Equatable, Sendable {
  public let cursor: UInt64
  public let data: Data

  public init(cursor: UInt64, data: Data) {
    self.cursor = cursor
    self.data = data
  }

  public var endCursor: UInt64 { cursor + UInt64(data.count) }
}

public enum TerminalEvent: Equatable, Sendable {
  case output(TerminalOutput)
  /// The raw wait status returned by waitpid(2).
  case exit(Int32)
}

public enum TerminalRuntimeError: Error, Equatable, Sendable, CustomStringConvertible {
  case terminalNotFound(TerminalID)
  case terminalExited(TerminalID, status: Int32)
  case replayUnavailable(requested: UInt64, availableFrom: UInt64)
  case invalidCursor(requested: UInt64, latest: UInt64)
  case slowConsumer

  public var description: String {
    switch self {
    case .terminalNotFound(let id):
      return "terminal not found: \(id.rawValue)"
    case .terminalExited(let id, let status):
      return "terminal exited: \(id.rawValue) (status \(status))"
    case .replayUnavailable(let requested, let availableFrom):
      return "terminal output at cursor \(requested) is no longer available; replay starts at \(availableFrom)"
    case .invalidCursor(let requested, let latest):
      return "terminal cursor \(requested) is ahead of latest cursor \(latest)"
    case .slowConsumer:
      return "terminal attachment could not keep up with output"
    }
  }
}

public protocol TerminalClient: Sendable {
  func createTerminal(configuration: TerminalConfiguration) async throws -> TerminalID
  func attach(to terminalID: TerminalID, after cursor: UInt64?) async throws -> TerminalAttachment
  func write(_ data: Data, to terminalID: TerminalID) async throws
  func resize(_ terminalID: TerminalID, to size: TerminalSize) async throws
  func close(_ terminalID: TerminalID) async
  func detach(_ attachmentID: UUID, from terminalID: TerminalID) async
}

extension TerminalClient {
  public func write(_ string: String, to terminalID: TerminalID) async throws {
    try await write(Data(string.utf8), to: terminalID)
  }

  public func interrupt(_ terminalID: TerminalID) async throws {
    try await write(Data([0x03]), to: terminalID)
  }
}

/// A bounded stream of events from one terminal. Dropping this value does not
/// detach it immediately; callers should use ``detach()`` when they are done.
public struct TerminalAttachment: Sendable {
  public let id: UUID
  public let terminalID: TerminalID
  public let events: AsyncThrowingStream<TerminalEvent, any Error>
  private let detachAction: @Sendable () async -> Void

  fileprivate init(
    id: UUID,
    terminalID: TerminalID,
    events: AsyncThrowingStream<TerminalEvent, any Error>,
    detachAction: @escaping @Sendable () async -> Void
  ) {
    self.id = id
    self.terminalID = terminalID
    self.events = events
    self.detachAction = detachAction
  }

  public func detach() async {
    await detachAction()
  }
}

/// A zero-scheduling-overhead attachment for an in-process renderer. Events are
/// called synchronously on the PTY callback thread and `Data` retains its existing
/// copy-on-write storage.
public struct LocalTerminalAttachment: Sendable {
  public let id: UUID
  public let terminalID: TerminalID
  private let detachAction: @Sendable () -> Void

  fileprivate init(id: UUID, terminalID: TerminalID, detachAction: @escaping @Sendable () -> Void) {
    self.id = id
    self.terminalID = terminalID
    self.detachAction = detachAction
  }

  public func detach() { detachAction() }
}

/// Owns PTYs independently of any UI or wire transport. Output is retained by
/// byte count and each attachment has its own bounded delivery queue.
public final class TerminalRuntime: Sendable {
  public struct Limits: Equatable, Sendable {
    public var replayBytes: Int
    public var attachmentEvents: Int

    public init(replayBytes: Int = 1024 * 1024, attachmentEvents: Int = 64) {
      self.replayBytes = max(0, replayBytes)
      self.attachmentEvents = max(1, attachmentEvents)
    }
  }

  private struct ReplayChunk: Sendable {
    var cursor: UInt64
    var data: Data
    var endCursor: UInt64 { cursor + UInt64(data.count) }
  }

  private final class Session: @unchecked Sendable {
    enum Lifecycle: Sendable {
      case running(PTYSession)
      case exited(Int32)
    }

    var lifecycle: Lifecycle
    var replay: [ReplayChunk] = []
    var replayByteCount = 0
    var nextCursor: UInt64 = 0
    var attachments: [UUID: AsyncThrowingStream<TerminalEvent, any Error>.Continuation] = [:]
    var localAttachments: [UUID: LocalAttachmentState] = [:]

    init(pty: PTYSession) {
      lifecycle = .running(pty)
    }
  }

  /// Mutable local-delivery state. Every field is accessed while `sessions` is
  /// locked; callbacks themselves are drained only after that lock is released.
  private final class LocalAttachmentState: @unchecked Sendable {
    let handler: @Sendable (TerminalEvent) -> Void
    var pending: Deque<TerminalEvent> = []
    var isDelivering = false
    var finishesAfterDelivery = false

    init(handler: @escaping @Sendable (TerminalEvent) -> Void) {
      self.handler = handler
    }
  }

  private let limits: Limits
  private let sessions = Mutex<[TerminalID: Session]>([:])

  public init(limits: Limits = Limits()) {
    self.limits = limits
  }

  public func createTerminal(configuration: TerminalConfiguration = TerminalConfiguration()) throws -> TerminalID {
    let pty = try PTYSession(
      shell: configuration.shell,
      workingDirectory: configuration.workingDirectory,
      columns: configuration.size.columns,
      rows: configuration.size.rows)
    let id = TerminalID()
    let session = Session(pty: pty)
    sessions.withLock { $0[id] = session }

    // PTY callbacks are already delivered off the main thread. Process them
    // synchronously so bytes retain read order and avoid allocating a Task for
    // every output chunk.
    pty.onOutput = { [weak self] data in
      self?.receive(data, from: id)
    }
    pty.onExit = { [weak self] status in
      self?.receiveExit(status, from: id)
    }
    return id
  }

  public func attach(
    to terminalID: TerminalID,
    after requestedCursor: UInt64? = nil
  ) throws -> TerminalAttachment {
    try sessions.withLock {
      try attachLocked(to: terminalID, after: requestedCursor, sessions: &$0)
    }
  }

  private func attachLocked(
    to terminalID: TerminalID,
    after requestedCursor: UInt64? = nil,
    sessions: inout [TerminalID: Session]
  ) throws -> TerminalAttachment {
    guard let session = sessions[terminalID] else {
      throw TerminalRuntimeError.terminalNotFound(terminalID)
    }

    let availableFrom = session.replay.first?.cursor ?? session.nextCursor
    let cursor = requestedCursor ?? availableFrom
    guard cursor >= availableFrom else {
      throw TerminalRuntimeError.replayUnavailable(
        requested: cursor, availableFrom: availableFrom)
    }
    guard cursor <= session.nextCursor else {
      throw TerminalRuntimeError.invalidCursor(
        requested: cursor, latest: session.nextCursor)
    }

    let attachmentID = UUID()
    let pair = AsyncThrowingStream<TerminalEvent, any Error>.makeStream(
      bufferingPolicy: .bufferingOldest(limits.attachmentEvents))
    session.attachments[attachmentID] = pair.continuation
    pair.continuation.onTermination = { [weak self] _ in
      // Termination can be invoked synchronously by `finish()` while runtime
      // state is borrowed by the mutex. Defer cleanup to avoid recursive lock
      // acquisition; this is a once-per-attachment cold path.
      Task { self?.detach(attachmentID, from: terminalID) }
    }

    if cursor < session.nextCursor {
      var replay = Data()
      for chunk in session.replay where chunk.endCursor > cursor {
        let offset = Int(max(cursor, chunk.cursor) - chunk.cursor)
        replay.append(chunk.data.dropFirst(offset))
      }
      if !replay.isEmpty {
        deliver(.output(TerminalOutput(cursor: cursor, data: replay)), to: attachmentID, in: session)
      }
    }
    if case .exited(let status) = session.lifecycle {
      deliver(.exit(status), to: attachmentID, in: session)
      session.attachments.removeValue(forKey: attachmentID)?.finish()
    }

    return TerminalAttachment(
      id: attachmentID,
      terminalID: terminalID,
      events: pair.stream,
      detachAction: { [weak self] in
        self?.detach(attachmentID, from: terminalID)
      })
  }

  public func attachLocally(
    to terminalID: TerminalID,
    after requestedCursor: UInt64? = nil,
    onEvent: @escaping @Sendable (TerminalEvent) -> Void
  ) throws -> LocalTerminalAttachment {
    let (attachment, shouldDrain) = try sessions.withLock { sessions in
      guard let session = sessions[terminalID] else {
        throw TerminalRuntimeError.terminalNotFound(terminalID)
      }
      let availableFrom = session.replay.first?.cursor ?? session.nextCursor
      let cursor = requestedCursor ?? availableFrom
      guard cursor >= availableFrom else {
        throw TerminalRuntimeError.replayUnavailable(requested: cursor, availableFrom: availableFrom)
      }
      guard cursor <= session.nextCursor else {
        throw TerminalRuntimeError.invalidCursor(requested: cursor, latest: session.nextCursor)
      }

      let attachmentID = UUID()
      let state = LocalAttachmentState(handler: onEvent)
      session.localAttachments[attachmentID] = state
      if cursor < session.nextCursor {
        var replay = Data()
        replay.reserveCapacity(Int(session.nextCursor - cursor))
        for chunk in session.replay where chunk.endCursor > cursor {
          let offset = Int(max(cursor, chunk.cursor) - chunk.cursor)
          replay.append(chunk.data.dropFirst(offset))
        }
        if !replay.isEmpty {
          state.pending.append(.output(TerminalOutput(cursor: cursor, data: replay)))
        }
      }
      if case .exited(let status) = session.lifecycle {
        state.pending.append(.exit(status))
        state.finishesAfterDelivery = true
      }
      let shouldDrain = beginLocalDeliveryIfNeeded(state)
      let attachment = LocalTerminalAttachment(id: attachmentID, terminalID: terminalID) { [weak self] in
        self?.detachLocal(attachmentID, from: terminalID)
      }
      return (attachment, shouldDrain)
    }
    if shouldDrain { drainLocalAttachment(attachment.id, from: terminalID) }
    return attachment
  }

  public func write(_ data: Data, to terminalID: TerminalID) throws {
    let pty = try runningPTY(for: terminalID)
    // Never hold the runtime lock across a potentially blocking write(2).
    try pty.write(data)
  }

  public func write(_ string: String, to terminalID: TerminalID) throws {
    let pty = try runningPTY(for: terminalID)
    try pty.write(string)
  }

  public func resize(_ terminalID: TerminalID, to size: TerminalSize) throws {
    let pty = try runningPTY(for: terminalID)
    try pty.resize(columns: size.columns, rows: size.rows)
  }

  private func runningPTY(for terminalID: TerminalID) throws -> PTYSession {
    try sessions.withLock { sessions in
      guard let session = sessions[terminalID] else {
        throw TerminalRuntimeError.terminalNotFound(terminalID)
      }
      switch session.lifecycle {
      case .running(let pty):
        return pty
      case .exited(let status):
        throw TerminalRuntimeError.terminalExited(terminalID, status: status)
      }
    }
  }

  public func close(_ terminalID: TerminalID) {
    let session = sessions.withLock { $0.removeValue(forKey: terminalID) }
    guard let session else { return }
    for continuation in session.attachments.values { continuation.finish() }
    session.attachments.removeAll(keepingCapacity: false)
    session.localAttachments.removeAll(keepingCapacity: false)
    if case .running(let pty) = session.lifecycle { pty.close() }
  }

  public func detach(_ attachmentID: UUID, from terminalID: TerminalID) {
    let continuation = sessions.withLock {
      $0[terminalID]?.attachments.removeValue(forKey: attachmentID)
    }
    continuation?.finish()
  }

  public func detachLocal(_ attachmentID: UUID, from terminalID: TerminalID) {
    sessions.withLock {
      _ = $0[terminalID]?.localAttachments.removeValue(forKey: attachmentID)
    }
  }

  private func receive(_ data: Data, from terminalID: TerminalID) {
    guard !data.isEmpty else { return }
    let localAttachmentsToDrain: [UUID] = sessions.withLock { sessions in
      guard let session = sessions[terminalID], case .running = session.lifecycle else { return [] }
      let output = TerminalOutput(cursor: session.nextCursor, data: data)
      session.nextCursor = output.endCursor
      appendToReplay(output, in: session)
      for attachmentID in Array(session.attachments.keys) {
        deliver(.output(output), to: attachmentID, in: session)
      }
      var result: [UUID] = []
      for (attachmentID, state) in session.localAttachments {
        state.pending.append(.output(output))
        if beginLocalDeliveryIfNeeded(state) { result.append(attachmentID) }
      }
      return result
    }
    for attachmentID in localAttachmentsToDrain {
      drainLocalAttachment(attachmentID, from: terminalID)
    }
  }

  private func appendToReplay(_ output: TerminalOutput, in session: Session) {
    guard limits.replayBytes > 0 else {
      session.replay.removeAll(keepingCapacity: false)
      session.replayByteCount = 0
      return
    }
    session.replay.append(ReplayChunk(cursor: output.cursor, data: output.data))
    session.replayByteCount += output.data.count

    while session.replayByteCount > limits.replayBytes, !session.replay.isEmpty {
      let excess = session.replayByteCount - limits.replayBytes
      if excess >= session.replay[0].data.count {
        session.replayByteCount -= session.replay.removeFirst().data.count
      } else {
        session.replay[0].cursor += UInt64(excess)
        session.replay[0].data.removeFirst(excess)
        session.replayByteCount -= excess
      }
    }
  }

  private func receiveExit(_ status: Int32, from terminalID: TerminalID) {
    let localAttachmentsToDrain: [UUID] = sessions.withLock { sessions in
      guard let session = sessions[terminalID], case .running = session.lifecycle else { return [] }
      session.lifecycle = .exited(status)
      for attachmentID in Array(session.attachments.keys) {
        deliver(.exit(status), to: attachmentID, in: session)
        session.attachments.removeValue(forKey: attachmentID)?.finish()
      }
      var result: [UUID] = []
      for (attachmentID, state) in session.localAttachments {
        state.pending.append(.exit(status))
        state.finishesAfterDelivery = true
        if beginLocalDeliveryIfNeeded(state) { result.append(attachmentID) }
      }
      return result
    }
    for attachmentID in localAttachmentsToDrain {
      drainLocalAttachment(attachmentID, from: terminalID)
    }
  }

  private func beginLocalDeliveryIfNeeded(_ state: LocalAttachmentState) -> Bool {
    guard !state.isDelivering, !state.pending.isEmpty else { return false }
    state.isDelivering = true
    return true
  }

  /// Drains one local attachment without holding `sessions`. The `isDelivering`
  /// flag preserves event order when PTY callbacks arrive concurrently.
  private func drainLocalAttachment(_ attachmentID: UUID, from terminalID: TerminalID) {
    while true {
      let delivery: (LocalAttachmentState, TerminalEvent)? = sessions.withLock { sessions in
        guard let session = sessions[terminalID],
          let state = session.localAttachments[attachmentID]
        else { return nil }
        guard !state.pending.isEmpty else {
          state.isDelivering = false
          if state.finishesAfterDelivery {
            session.localAttachments.removeValue(forKey: attachmentID)
          }
          return nil
        }
        return (state, state.pending.popFirst()!)
      }
      guard let (state, event) = delivery else { return }
      state.handler(event)
    }
  }

  private func deliver(
    _ event: TerminalEvent,
    to attachmentID: UUID,
    in session: Session
  ) {
    guard let continuation = session.attachments[attachmentID] else { return }
    switch continuation.yield(event) {
    case .enqueued:
      break
    case .dropped:
      session.attachments.removeValue(forKey: attachmentID)?
        .finish(throwing: TerminalRuntimeError.slowConsumer)
    case .terminated:
      session.attachments.removeValue(forKey: attachmentID)
    @unknown default:
      session.attachments.removeValue(forKey: attachmentID)?
        .finish(throwing: TerminalRuntimeError.slowConsumer)
    }
  }
}

/// The GUI's local adapter. It has the same async boundary a future socket
/// client will have, while forwarding requests directly to the runtime actor.
public final class InProcessTerminalClient: TerminalClient, @unchecked Sendable {
  public let runtime: TerminalRuntime

  public init(runtime: TerminalRuntime = TerminalRuntime()) {
    self.runtime = runtime
  }

  // The GUI uses these synchronous methods on the in-process transport. They
  // deliberately avoid task creation and actor scheduling on the keystroke path.
  public func createSynchronously(
    configuration: TerminalConfiguration = TerminalConfiguration()
  ) throws -> TerminalID {
    try runtime.createTerminal(configuration: configuration)
  }

  public func attachSynchronously(
    to terminalID: TerminalID,
    after cursor: UInt64? = nil,
    onEvent: @escaping @Sendable (TerminalEvent) -> Void
  ) throws -> LocalTerminalAttachment {
    try runtime.attachLocally(to: terminalID, after: cursor, onEvent: onEvent)
  }

  public func writeSynchronously(_ data: Data, to terminalID: TerminalID) throws {
    try runtime.write(data, to: terminalID)
  }

  public func writeSynchronously(_ string: String, to terminalID: TerminalID) throws {
    try runtime.write(string, to: terminalID)
  }

  public func resizeSynchronously(_ terminalID: TerminalID, to size: TerminalSize) throws {
    try runtime.resize(terminalID, to: size)
  }

  public func closeSynchronously(_ terminalID: TerminalID) {
    runtime.close(terminalID)
  }

  public func detachSynchronously(_ attachment: TerminalAttachment) {
    runtime.detach(attachment.id, from: attachment.terminalID)
  }

  public func createTerminal(configuration: TerminalConfiguration) async throws -> TerminalID {
    try runtime.createTerminal(configuration: configuration)
  }

  public func attach(to terminalID: TerminalID, after cursor: UInt64? = nil) async throws
    -> TerminalAttachment
  {
    try runtime.attach(to: terminalID, after: cursor)
  }

  public func write(_ data: Data, to terminalID: TerminalID) async throws {
    try runtime.write(data, to: terminalID)
  }

  public func resize(_ terminalID: TerminalID, to size: TerminalSize) async throws {
    try runtime.resize(terminalID, to: size)
  }

  public func close(_ terminalID: TerminalID) async {
    runtime.close(terminalID)
  }

  public func detach(_ attachmentID: UUID, from terminalID: TerminalID) async {
    runtime.detach(attachmentID, from: terminalID)
  }
}
