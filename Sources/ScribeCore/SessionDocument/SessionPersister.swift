import Foundation
import SystemPackage

// MARK: - SessionPersister

/// Backing store paired with a ``SessionDocument`` by its owner.
///
/// The owner (typically a chat host) writes through the persister
/// **before** committing the matching change to the doc — that order
/// means a persistence failure never leaves the in-memory rope ahead of
/// disk. The persister itself is `~Copyable`-agnostic: it works with
/// plain `[ScribeMessage]` values.
///
/// Implementations are responsible for the on-disk schema (CLI uses
/// JSONL + `metadata.json`; embedders may provide an in-memory or
/// remote persister).
///
/// Conformers are `Sendable`; if they hold mutable file handles or
/// per-session state, they must serialize their own access.
public protocol SessionPersister: Sendable {

  /// Append messages to the currently-tracked session.
  func append(_ messages: [ScribeMessage]) async throws

  /// Create a new session adjacent to the current one whose initial
  /// content is `newContent`, switch self to track that new session for
  /// subsequent appends, and return its identity.
  ///
  /// The persister knows where to put new sessions (typically a sibling
  /// directory under the same root) and how to seed metadata from the
  /// parent. `parentSessionId` + `parentForkPoint` are recorded in
  /// metadata for browsing / debugging only — the persister does not
  /// use them to reconstruct content (the caller already did that work
  /// to produce `newContent`).
  func fork(
    newContent: [ScribeMessage],
    newSessionId: UUID,
    parentSessionId: UUID,
    parentForkPoint: Int
  ) async throws -> (sessionId: UUID, directory: FilePath)
}

// MARK: - InMemorySessionPersister

/// No-op persister for embedders and tests that don't want disk side
/// effects. Fork still produces a synthetic directory path so the
/// owner's identity tracking keeps working.
public final class InMemorySessionPersister: SessionPersister {
  public init() {}

  public func append(_ messages: [ScribeMessage]) async throws {}

  public func fork(
    newContent: [ScribeMessage],
    newSessionId: UUID,
    parentSessionId: UUID,
    parentForkPoint: Int
  ) async throws -> (sessionId: UUID, directory: FilePath) {
    (newSessionId, FilePath("/in-memory/\(newSessionId.uuidString)"))
  }
}
