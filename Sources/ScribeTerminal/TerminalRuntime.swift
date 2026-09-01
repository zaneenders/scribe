import Foundation

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
  case replayUnavailable(requested: UInt64, availableFrom: UInt64)
  case invalidCursor(requested: UInt64, latest: UInt64)
  case slowConsumer

  public var description: String {
    switch self {
    case .terminalNotFound(let id):
      return "terminal not found: \(id.rawValue)"
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

public extension TerminalClient {
  func write(_ string: String, to terminalID: TerminalID) async throws {
    try await write(Data(string.utf8), to: terminalID)
  }

  func interrupt(_ terminalID: TerminalID) async throws {
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

/// Owns PTYs independently of any UI or wire transport. Output is retained by
/// byte count and each attachment has its own bounded delivery queue.
public actor TerminalRuntime {
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
    let pty: PTYSession
    var replay: [ReplayChunk] = []
    var replayByteCount = 0
    var nextCursor: UInt64 = 0
    var exitStatus: Int32?
    var attachments: [UUID: AsyncThrowingStream<TerminalEvent, any Error>.Continuation] = [:]

    init(pty: PTYSession) {
      self.pty = pty
    }
  }

  private let limits: Limits
  private var sessions: [TerminalID: Session] = [:]

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
    sessions[id] = session

    pty.onOutput = { [weak self] data in
      Task { await self?.receive(data, from: id) }
    }
    pty.onExit = { [weak self] status in
      Task { await self?.receiveExit(status, from: id) }
    }
    return id
  }

  public func attach(
    to terminalID: TerminalID,
    after requestedCursor: UInt64? = nil
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
      Task { await self?.detach(attachmentID, from: terminalID) }
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
    if let status = session.exitStatus {
      deliver(.exit(status), to: attachmentID, in: session)
      session.attachments.removeValue(forKey: attachmentID)?.finish()
    }

    return TerminalAttachment(
      id: attachmentID,
      terminalID: terminalID,
      events: pair.stream,
      detachAction: { [weak self] in
        await self?.detach(attachmentID, from: terminalID)
      })
  }

  public func write(_ data: Data, to terminalID: TerminalID) throws {
    guard let session = sessions[terminalID] else {
      throw TerminalRuntimeError.terminalNotFound(terminalID)
    }
    session.pty.write(data)
  }

  public func resize(_ terminalID: TerminalID, to size: TerminalSize) throws {
    guard let session = sessions[terminalID] else {
      throw TerminalRuntimeError.terminalNotFound(terminalID)
    }
    session.pty.resize(columns: size.columns, rows: size.rows)
  }

  public func close(_ terminalID: TerminalID) {
    sessions[terminalID]?.pty.close()
  }

  public func detach(_ attachmentID: UUID, from terminalID: TerminalID) {
    sessions[terminalID]?.attachments.removeValue(forKey: attachmentID)?.finish()
  }

  private func receive(_ data: Data, from terminalID: TerminalID) {
    guard !data.isEmpty, let session = sessions[terminalID], session.exitStatus == nil else { return }
    let output = TerminalOutput(cursor: session.nextCursor, data: data)
    session.nextCursor = output.endCursor
    appendToReplay(output, in: session)
    for attachmentID in Array(session.attachments.keys) {
      deliver(.output(output), to: attachmentID, in: session)
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
    guard let session = sessions[terminalID], session.exitStatus == nil else { return }
    session.exitStatus = status
    for attachmentID in Array(session.attachments.keys) {
      deliver(.exit(status), to: attachmentID, in: session)
      session.attachments.removeValue(forKey: attachmentID)?.finish()
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

  public func createTerminal(configuration: TerminalConfiguration) async throws -> TerminalID {
    try await runtime.createTerminal(configuration: configuration)
  }

  public func attach(to terminalID: TerminalID, after cursor: UInt64? = nil) async throws
    -> TerminalAttachment
  {
    try await runtime.attach(to: terminalID, after: cursor)
  }

  public func write(_ data: Data, to terminalID: TerminalID) async throws {
    try await runtime.write(data, to: terminalID)
  }

  public func resize(_ terminalID: TerminalID, to size: TerminalSize) async throws {
    try await runtime.resize(terminalID, to: size)
  }

  public func close(_ terminalID: TerminalID) async {
    await runtime.close(terminalID)
  }

  public func detach(_ attachmentID: UUID, from terminalID: TerminalID) async {
    await runtime.detach(attachmentID, from: terminalID)
  }
}
