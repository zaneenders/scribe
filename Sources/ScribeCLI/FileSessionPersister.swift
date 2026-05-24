import Foundation
import Logging
import _NIOFileSystem
import ScribeCore
import Synchronization
import SystemPackage

// MARK: - FileSessionPersister

/// Disk-backed ``SessionPersister`` for the CLI: appends to `messages.jsonl`
/// and writes `metadata.json` under `sessions/{uuid}/`.
///
/// Holds an open `MessagesAppender` for the active session and swaps it on
/// fork. All mutation happens under a `Mutex` so the doc can call from any
/// task without coordinating itself.
final class FileSessionPersister: SessionPersister {

  // MARK: - State

  private struct State {
    var sessionId: UUID
    var directory: FilePath
    var appender: ChatSessionStore.MessagesAppender
  }

  private let state: Mutex<State>
  private let model: String
  private let cwd: String
  private let baseURL: String?
  private let scribeVersion: String?
  private let logger: Logger

  // MARK: - Init

  /// Open a persister for a fresh or resumed session.
  ///
  /// For a fresh session (`isNewSession == true`), writes the initial
  /// `metadata.json`. For a resumed session, assumes metadata + jsonl
  /// already exist; the doc seeds itself from caller-provided messages.
  static func open(
    sessionId: UUID,
    directory: FilePath,
    sessionCreatedAt: Date,
    isNewSession: Bool,
    model: String,
    cwd: String,
    baseURL: String?,
    scribeVersion: String?,
    logger: Logger
  ) async throws -> FileSessionPersister {
    if isNewSession {
      let meta = ChatSessionMetadata(
        id: sessionId,
        createdAt: sessionCreatedAt,
        model: model,
        cwd: cwd,
        baseURL: baseURL,
        scribeVersion: scribeVersion
      )
      try await ChatSessionStore.saveMetadata(meta, to: directory)
    }
    let appender = try ChatSessionStore.MessagesAppender(directory: directory)
    return FileSessionPersister(
      initialState: State(sessionId: sessionId, directory: directory, appender: appender),
      model: model,
      cwd: cwd,
      baseURL: baseURL,
      scribeVersion: scribeVersion,
      logger: logger
    )
  }

  private init(
    initialState: State,
    model: String,
    cwd: String,
    baseURL: String?,
    scribeVersion: String?,
    logger: Logger
  ) {
    self.state = Mutex(initialState)
    self.model = model
    self.cwd = cwd
    self.baseURL = baseURL
    self.scribeVersion = scribeVersion
    self.logger = logger
  }

  // MARK: - SessionPersister

  func append(_ messages: [ScribeMessage]) async throws {
    guard !messages.isEmpty else { return }
    do {
      try state.withLock { try $0.appender.append(messages) }
    } catch {
      // Persistence is best-effort from the user's perspective — the doc
      // already updated its in-memory rope. Log the failure but don't
      // throw; tearing down the chat for a disk hiccup would be worse
      // than continuing without that turn on disk.
      logger.error(
        "session.persister.append.fail",
        metadata: ["err": "\(String(describing: error))"])
    }
  }

  func fork(
    cutAt: Int,
    tail: [ScribeMessage],
    currentMessages: [ScribeMessage],
    newSessionId: UUID,
    parentSessionId: UUID
  ) async throws -> (sessionId: UUID, directory: FilePath) {
    precondition(cutAt >= 0 && cutAt <= currentMessages.count, "fork cutAt out of bounds")

    let currentDir = state.withLock { $0.directory }
    let sessionsRoot = currentDir.removingLastComponent()
    let newDir = sessionsRoot.appendingPathComponent(newSessionId.uuidString)

    // Create the new directory + write metadata + write content. All-or-
    // nothing: if any step fails the doc rolls back its identity swap.
    try await FileSystem.shared.createDirectory(
      at: newDir, withIntermediateDirectories: true)

    let meta = ChatSessionMetadata(
      id: newSessionId,
      createdAt: Date(),
      model: model,
      cwd: cwd,
      baseURL: baseURL,
      scribeVersion: scribeVersion,
      parentSessionId: parentSessionId,
      forkedAtIndex: cutAt
    )
    try await ChatSessionStore.saveMetadata(meta, to: newDir)

    let newAppender = try ChatSessionStore.MessagesAppender(directory: newDir)
    let prefix = Array(currentMessages.prefix(cutAt))
    try newAppender.append(prefix)
    if !tail.isEmpty {
      try newAppender.append(tail)
    }

    // Swap appender + identity atomically. The old appender's file handle
    // drops with its last reference; nothing further writes to the parent
    // session's JSONL.
    state.withLock { s in
      s.sessionId = newSessionId
      s.directory = newDir
      s.appender = newAppender
    }

    logger.notice(
      "session.persister.fork",
      metadata: [
        "parent": "\(parentSessionId.uuidString)",
        "child": "\(newSessionId.uuidString)",
        "cut_at": "\(cutAt)",
        "tail_messages": "\(tail.count)",
        "new_dir": "\(newDir.string)",
      ])

    return (newSessionId, newDir)
  }
}
