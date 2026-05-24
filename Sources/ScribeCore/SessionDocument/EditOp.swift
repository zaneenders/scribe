import Foundation
import SystemPackage

// MARK: - EditOp

/// The vocabulary of mutations that can be applied to a ``SessionDocument``.
///
/// Every command that modifies session history — the agent's per-turn
/// append, `/fork`, `/tldr`, and anything future — flows through
/// ``SessionDocument/apply(_:)`` as one of these cases. The doc routes the
/// op to its in-memory rope and its persister atomically, then emits the
/// matching ``ChangeSet`` to subscribers.
public enum EditOp: Sendable {

  /// Append the given messages to the tail of the current session.
  /// Issued by ``ScribeAgent`` at the end of every turn.
  case append([ScribeMessage])

  /// Implements `/fork`. Creates a new session whose content is
  /// `messages[0..<cutAt]` of the current document, becomes that session
  /// for subsequent writes, and preserves the original on disk.
  ///
  /// - Parameters:
  ///   - cutAt: Index in the current rope (must be a value returned by
  ///     ``SessionDocument/safeForkBoundaries()``).
  ///   - newSessionId: Identity for the forked session.
  case fork(cutAt: Int, newSessionId: UUID)

  /// Implements `/tldr`. Creates a new session whose content is
  /// `messages[0..<startCut] + replacement + messages[endCut..<count]`,
  /// becomes that session for subsequent writes, and preserves the
  /// original on disk.
  ///
  /// - Parameters:
  ///   - startCut: First index dropped (must be a safe fork boundary).
  ///   - endCut: First index kept after the splice (must be a safe fork
  ///     boundary, and `>= startCut`).
  ///   - replacement: Messages spliced in between the head and the tail —
  ///     typically a single assistant summary produced by
  ///     ``SessionSummarizer``-style condensers.
  ///   - newSessionId: Identity for the forked session.
  case forkSplice(
    startCut: Int,
    endCut: Int,
    replacement: [ScribeMessage],
    newSessionId: UUID
  )
}

// MARK: - ChangeSet

/// What a ``SessionDocument`` observer sees after an ``EditOp`` lands.
public enum ChangeSet: Sendable {

  /// New messages were appended to the existing identity. `range` is the
  /// half-open index range of new messages in the rope after the append.
  case appended(range: Range<Int>)

  /// The document moved to a new session identity (its rope content has
  /// been entirely replaced and its writer points at a new directory).
  /// Subscribers should re-read the full snapshot.
  case identityChanged(
    previousSessionId: UUID,
    sessionId: UUID,
    directory: FilePath,
    reason: IdentityChangeReason
  )

  public enum IdentityChangeReason: Sendable {
    case fork
    case forkSplice
  }
}
