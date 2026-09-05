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
  case attachmentAlreadyAwaiting
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
    case .attachmentAlreadyAwaiting:
      return "terminal attachment already has a consumer awaiting an event"
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

/// The event sequence for a terminal attachment. The sequence has a single
/// consumer; copying an iterator and awaiting both copies concurrently is an error.
public struct TerminalEventStream: AsyncSequence, Sendable {
  public typealias Element = TerminalEvent

  public struct AsyncIterator: AsyncIteratorProtocol {
    private let nextEvent: @Sendable () async throws -> TerminalEvent?

    fileprivate init(nextEvent: @escaping @Sendable () async throws -> TerminalEvent?) {
      self.nextEvent = nextEvent
    }

    public mutating func next() async throws -> TerminalEvent? {
      try await nextEvent()
    }
  }

  private let nextEvent: @Sendable () async throws -> TerminalEvent?

  fileprivate init(nextEvent: @escaping @Sendable () async throws -> TerminalEvent?) {
    self.nextEvent = nextEvent
  }

  public func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(nextEvent: nextEvent)
  }
}

/// A bounded stream of events from one terminal. Dropping this value does not
/// detach it immediately; callers should use ``detach()`` when they are done.
public struct TerminalAttachment: Sendable {
  public let id: UUID
  public let terminalID: TerminalID
  public let events: TerminalEventStream
  private let detachAction: @Sendable () async -> Void

  fileprivate init(
    id: UUID,
    terminalID: TerminalID,
    events: TerminalEventStream,
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
    /// Maximum unread output bytes retained for one asynchronous attachment.
    public var attachmentBytes: Int

    public init(replayBytes: Int = 1024 * 1024, attachmentBytes: Int = 1024 * 1024) {
      self.replayBytes = max(0, replayBytes)
      self.attachmentBytes = max(1, attachmentBytes)
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
    var attachments: [UUID: AsyncAttachmentState] = [:]
    var localAttachments: [UUID: LocalAttachmentState] = [:]

    init(pty: PTYSession) {
      lifecycle = .running(pty)
    }
  }

  /// Mutable async-delivery state. Queue fields are protected by `sessions`;
  /// exactly one consumer may suspend in `next()` at a time.
  private final class AsyncAttachmentState: @unchecked Sendable {
    var pending: Deque<TerminalEvent> = []
    var pendingOutputBytes = 0
    var waiter: CheckedContinuation<TerminalEvent?, any Error>?
    var terminalError: (any Error)?
    var isFinished = false

    func appendOutput(_ output: TerminalOutput) {
      pendingOutputBytes += output.data.count
      if let last = pending.popLast() {
        if case .output(let previous) = last, previous.endCursor == output.cursor {
          var data = previous.data
          data.append(output.data)
          pending.append(.output(TerminalOutput(cursor: previous.cursor, data: data)))
          return
        }
        pending.append(last)
      }
      pending.append(.output(output))
    }
  }

  private enum AsyncAttachmentAction {
    case event(CheckedContinuation<TerminalEvent?, any Error>, TerminalEvent)
    case finish(CheckedContinuation<TerminalEvent?, any Error>)
    case fail(CheckedContinuation<TerminalEvent?, any Error>, any Error)
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
    let state = AsyncAttachmentState()
    session.attachments[attachmentID] = state

    if cursor < session.nextCursor {
      var replay = Data()
      replay.reserveCapacity(Int(session.nextCursor - cursor))
      for chunk in session.replay where chunk.endCursor > cursor {
        let offset = Int(max(cursor, chunk.cursor) - chunk.cursor)
        replay.append(chunk.data.dropFirst(offset))
      }
      if !replay.isEmpty {
        state.appendOutput(TerminalOutput(cursor: cursor, data: replay))
      }
    }
    if case .exited(let status) = session.lifecycle {
      state.pending.append(.exit(status))
      state.isFinished = true
    }

    return TerminalAttachment(
      id: attachmentID,
      terminalID: terminalID,
      events: TerminalEventStream { [weak self] in
        guard let self else { return nil }
        return try await withTaskCancellationHandler {
          try Task.checkCancellation()
          return try await self.nextEvent(attachmentID, from: terminalID)
        } onCancel: {
          self.detach(attachmentID, from: terminalID)
        }
      },
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
    let (session, actions) = sessions.withLock { sessions -> (Session?, [AsyncAttachmentAction]) in
      guard let session = sessions.removeValue(forKey: terminalID) else { return (nil, []) }
      let actions = session.attachments.values.compactMap { finishAsyncAttachment($0) }
      session.attachments.removeAll(keepingCapacity: false)
      session.localAttachments.removeAll(keepingCapacity: false)
      return (session, actions)
    }
    resume(actions)
    guard let session else { return }
    if case .running(let pty) = session.lifecycle { pty.close() }
  }

  public func detach(_ attachmentID: UUID, from terminalID: TerminalID) {
    let action = sessions.withLock { sessions -> AsyncAttachmentAction? in
      guard let state = sessions[terminalID]?.attachments.removeValue(forKey: attachmentID) else {
        return nil
      }
      return finishAsyncAttachment(state)
    }
    if let action { resume(action) }
  }

  private func nextEvent(_ attachmentID: UUID, from terminalID: TerminalID) async throws -> TerminalEvent? {
    try await withCheckedThrowingContinuation { continuation in
      let action = sessions.withLock { sessions -> AsyncAttachmentAction? in
        guard let state = sessions[terminalID]?.attachments[attachmentID] else {
          return .finish(continuation)
        }
        if !state.pending.isEmpty {
          let event = state.pending.popFirst()!
          if case .output(let output) = event {
            state.pendingOutputBytes -= output.data.count
          }
          return .event(continuation, event)
        }
        if let error = state.terminalError {
          sessions[terminalID]?.attachments.removeValue(forKey: attachmentID)
          return .fail(continuation, error)
        }
        if state.isFinished {
          sessions[terminalID]?.attachments.removeValue(forKey: attachmentID)
          return .finish(continuation)
        }
        guard state.waiter == nil else {
          return .fail(continuation, TerminalRuntimeError.attachmentAlreadyAwaiting)
        }
        state.waiter = continuation
        return nil
      }
      if let action { resume(action) }
    }
  }

  private func finishAsyncAttachment(_ state: AsyncAttachmentState) -> AsyncAttachmentAction? {
    state.pending.removeAll(keepingCapacity: false)
    state.pendingOutputBytes = 0
    state.isFinished = true
    guard let waiter = state.waiter else { return nil }
    state.waiter = nil
    return .finish(waiter)
  }

  private func resume(_ actions: [AsyncAttachmentAction]) {
    for action in actions { resume(action) }
  }

  private func resume(_ action: AsyncAttachmentAction) {
    switch action {
    case .event(let continuation, let event): continuation.resume(returning: event)
    case .finish(let continuation): continuation.resume(returning: nil)
    case .fail(let continuation, let error): continuation.resume(throwing: error)
    }
  }

  public func detachLocal(_ attachmentID: UUID, from terminalID: TerminalID) {
    sessions.withLock {
      _ = $0[terminalID]?.localAttachments.removeValue(forKey: attachmentID)
    }
  }

  private func receive(_ data: Data, from terminalID: TerminalID) {
    guard !data.isEmpty else { return }
    let (actions, localAttachmentsToDrain): ([AsyncAttachmentAction], [UUID]) = sessions.withLock { sessions in
      guard let session = sessions[terminalID], case .running = session.lifecycle else { return ([], []) }
      let output = TerminalOutput(cursor: session.nextCursor, data: data)
      session.nextCursor = output.endCursor
      appendToReplay(output, in: session)
      var actions: [AsyncAttachmentAction] = []
      for attachmentID in Array(session.attachments.keys) {
        if let action = deliverOutput(output, to: attachmentID, in: session) { actions.append(action) }
      }
      var localAttachmentsToDrain: [UUID] = []
      for (attachmentID, state) in session.localAttachments {
        state.pending.append(.output(output))
        if beginLocalDeliveryIfNeeded(state) { localAttachmentsToDrain.append(attachmentID) }
      }
      return (actions, localAttachmentsToDrain)
    }
    resume(actions)
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
    let (actions, localAttachmentsToDrain): ([AsyncAttachmentAction], [UUID]) = sessions.withLock { sessions in
      guard let session = sessions[terminalID], case .running = session.lifecycle else { return ([], []) }
      session.lifecycle = .exited(status)
      var actions: [AsyncAttachmentAction] = []
      for attachmentID in Array(session.attachments.keys) {
        if let action = deliverExit(status, to: attachmentID, in: session) { actions.append(action) }
      }
      var localAttachmentsToDrain: [UUID] = []
      for (attachmentID, state) in session.localAttachments {
        state.pending.append(.exit(status))
        state.finishesAfterDelivery = true
        if beginLocalDeliveryIfNeeded(state) { localAttachmentsToDrain.append(attachmentID) }
      }
      return (actions, localAttachmentsToDrain)
    }
    resume(actions)
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

  private func deliverOutput(
    _ output: TerminalOutput,
    to attachmentID: UUID,
    in session: Session
  ) -> AsyncAttachmentAction? {
    guard let state = session.attachments[attachmentID], state.terminalError == nil else { return nil }
    if let waiter = state.waiter, state.pending.isEmpty {
      state.waiter = nil
      return .event(waiter, .output(output))
    }
    state.appendOutput(output)
    guard state.pendingOutputBytes > limits.attachmentBytes else { return nil }
    state.pending.removeAll(keepingCapacity: false)
    state.pendingOutputBytes = 0
    state.terminalError = TerminalRuntimeError.slowConsumer
    state.isFinished = true
    guard let waiter = state.waiter else { return nil }
    state.waiter = nil
    return .fail(waiter, TerminalRuntimeError.slowConsumer)
  }

  private func deliverExit(
    _ status: Int32,
    to attachmentID: UUID,
    in session: Session
  ) -> AsyncAttachmentAction? {
    guard let state = session.attachments[attachmentID], state.terminalError == nil else { return nil }
    state.isFinished = true
    if let waiter = state.waiter, state.pending.isEmpty {
      state.waiter = nil
      return .event(waiter, .exit(status))
    }
    state.pending.append(.exit(status))
    return nil
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
