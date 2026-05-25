import Foundation
import SystemPackage


/// The vocabulary of mutations routed through a host's `applyEdit`.
///
/// Every command that modifies session history — per-turn append, `/fork`,
/// `/tldr`, and anything future — is expressed as one of these cases.
/// The host orchestrates persistence and in-memory doc changes; the doc
/// itself has no knowledge of ``EditOp``.
public enum EditOp: Sendable {

  /// Append incoming messages to the tail of the current session.
  /// Issued by the coordinator after a ``ScribeAgent`` turn completes.
  case append([ScribeMessage])

  /// Implements `/fork`. Creates a new session whose content is
  /// `messages[0..<cutAt]` of the current document.
  ///
  /// - Parameters:
  ///   - cutAt: Index in the current rope (must be a value returned by
  ///     ``SessionDocument/safeForkBoundaries()``).
  ///   - newSessionId: Identity for the forked session.
  case fork(cutAt: Int, newSessionId: UUID)

  /// Implements `/tldr`. Creates a new session whose content is
  /// `messages[0..<startCut] + replacement + messages[endCut..<count]`.
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


/// Parent linkage recorded when a session is forked or summarized.
public struct SessionParent: Sendable {
  public let sessionId: UUID
  public let forkPoint: Int

  public init(sessionId: UUID, forkPoint: Int) {
    self.sessionId = sessionId
    self.forkPoint = forkPoint
  }
}
