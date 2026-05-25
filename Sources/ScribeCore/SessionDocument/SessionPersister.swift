import Foundation
import SystemPackage


/// Sendable snapshot for persisting a new session at an I/O boundary.
///
/// Built from a successor ``SessionDocument`` on the owner's isolation
/// domain immediately before crossing `await` into a ``SessionPersister``.
public struct SessionPersistenceSnapshot: Sendable {
  public let sessionId: UUID
  public let directory: FilePath
  public let messages: [ScribeMessage]

  public init(_ document: borrowing SessionDocument) {
    sessionId = document.sessionId
    directory = document.directory
    var msgs: [ScribeMessage] = []
    msgs.reserveCapacity(document.count)
    for i in 0..<document.count {
      msgs.append(document[i])
    }
    messages = msgs
  }
}


/// Backing store paired with a ``SessionDocument`` by its owner.
///
/// The owner (typically a chat host) writes through the persister
/// **before** committing the matching change to the doc — that order
/// means a persistence failure never leaves the in-memory rope ahead of
/// disk. The persister itself is `~Copyable`-agnostic: it borrows the doc
/// by index for fork writes and takes plain message arrays for incoming
/// appends.
///
/// Implementations are responsible for the on-disk schema (CLI uses
/// JSONL + `metadata.json`; embedders may provide an in-memory or
/// remote persister).
///
/// Conformers are `Sendable`; if they hold mutable file handles or
/// per-session state, they must serialize their own access.
public protocol SessionPersister: Sendable {

  /// Append *incoming* messages to the active session's log.
  func append(_ messages: [ScribeMessage]) async throws

  /// Where the persister would lay down a new session with `newSessionId`.
  /// Called by the owner before constructing a successor doc so the doc
  /// is born with its real directory.
  func directory(for newSessionId: UUID) -> FilePath

  /// Persist a new session and switch subsequent appends to it.
  /// `snapshot` is built from a successor doc on the owner's isolation
  /// domain immediately before this call.
  func openSession(
    _ snapshot: SessionPersistenceSnapshot,
    parent: SessionParent
  ) async throws
}


/// No-op persister for embedders and tests that don't want disk side
/// effects. Fork still produces a synthetic directory path so the
/// owner's identity tracking keeps working.
public final class InMemorySessionPersister: SessionPersister {
  public init() {}

  public func append(_ messages: [ScribeMessage]) async throws {}

  public func directory(for newSessionId: UUID) -> FilePath {
    FilePath("/in-memory/\(newSessionId.uuidString)")
  }

  public func openSession(
    _ snapshot: SessionPersistenceSnapshot,
    parent: SessionParent
  ) async throws {}
}
