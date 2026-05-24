import Foundation
import SystemPackage

// MARK: - SessionPersister

/// Backing store for a ``SessionDocument``. The doc routes every write
/// through here; in-memory rope changes happen alongside the persister
/// call so the two cannot diverge.
///
/// Implementations are responsible for the on-disk schema (CLI uses JSONL
/// + `metadata.json`; embedders may provide an in-memory or remote
/// persister). The doc itself is schema-agnostic.
///
/// Conformers are `Sendable`; if they hold mutable file handles or
/// per-session state, they must serialize their own access (the doc holds
/// the persister and may call into it from its actor).
public protocol SessionPersister: Sendable {

  /// Append messages to the currently-tracked session.
  ///
  /// Called by ``SessionDocument`` on `apply(.append(...))` after the rope
  /// has been updated in memory. A failure here is reported back to the
  /// caller; the doc keeps the in-memory append (the on-disk JSONL is best
  /// effort, never a blocker for ongoing chat).
  func append(_ messages: [ScribeMessage]) async throws

  /// Create a new session adjacent to the current one whose content is
  /// `currentMessages[0..<cutAt] + tail`, switch self to track that new
  /// session for subsequent appends, and return its identity.
  ///
  /// The persister knows where to put new sessions (typically a sibling
  /// directory under the same root) and how to seed metadata from the
  /// parent (model, cwd, base URL, scribe version, parent-id linkage).
  func fork(
    cutAt: Int,
    tail: [ScribeMessage],
    currentMessages: [ScribeMessage],
    newSessionId: UUID,
    parentSessionId: UUID
  ) async throws -> (sessionId: UUID, directory: FilePath)
}

// MARK: - InMemorySessionPersister

/// No-op persister for embedders and tests that don't want disk side
/// effects. Fork still produces a synthetic directory path so the doc's
/// identity tracking keeps working.
public final class InMemorySessionPersister: SessionPersister {
  public init() {}

  public func append(_ messages: [ScribeMessage]) async throws {}

  public func fork(
    cutAt: Int,
    tail: [ScribeMessage],
    currentMessages: [ScribeMessage],
    newSessionId: UUID,
    parentSessionId: UUID
  ) async throws -> (sessionId: UUID, directory: FilePath) {
    (newSessionId, FilePath("/in-memory/\(newSessionId.uuidString)"))
  }
}
