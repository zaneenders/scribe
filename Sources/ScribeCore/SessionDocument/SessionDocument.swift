import Foundation
import Logging
import ScribeLLM
import SystemPackage

// MARK: - SessionDocument

/// The single source of truth for a chat session's messages and identity.
///
/// Owns a ``MessageRope`` and the session identity (id + on-disk
/// directory). `SessionDocument` is `~Copyable`: the compiler enforces a
/// single owner (the chat host). All reads are synchronous borrows; all
/// mutations are synchronous and take `inout self`.
///
/// Persistence is **not** the doc's concern. The owner pairs the doc
/// with a ``SessionPersister`` and orchestrates the two — write to disk
/// first, then commit the in-memory change here, so a persistence
/// failure never leaves the rope ahead of disk. Keeping the doc's API
/// sync-only sidesteps the "mutating async on actor-isolated property"
/// rule that would otherwise force `nonisolated(unsafe)` on the host.
public struct SessionDocument: ~Copyable {

  // MARK: - Identity

  public private(set) var sessionId: UUID
  public private(set) var directory: FilePath

  // MARK: - Truth

  private var rope: MessageRope
  private let logger: Logger

  // MARK: - Init

  /// Open a document over an in-memory ``MessageRope`` seeded with
  /// `initialMessages`.
  ///
  /// - Parameters:
  ///   - sessionId: Session UUID (matches the on-disk directory name).
  ///   - directory: Session directory (`sessions/{uuid}`). Tracked for
  ///     identity; the owner's persister is what actually reads/writes
  ///     inside this path.
  ///   - initialMessages: Pre-loaded transcript. For new sessions this
  ///     is `[ScribeMessage(role: .system, content: prompt)]`. For
  ///     resumed sessions it's whatever the owner restored from disk.
  ///   - logger: Session logger; the doc emits `session.doc.*` events
  ///     for each applied op.
  public init(
    sessionId: UUID,
    directory: FilePath,
    initialMessages: [ScribeMessage],
    logger: Logger
  ) {
    self.sessionId = sessionId
    self.directory = directory
    self.rope = MessageRope(initialMessages.toChatMessages())
    self.logger = logger
  }

  // MARK: - Reading

  public var count: Int { rope.count }

  public var isEmpty: Bool { rope.isEmpty }

  /// Materialise the whole transcript. O(n). Prefer ``window(from:count:)``
  /// when the caller only needs a viewport.
  public borrowing func snapshot() -> [ScribeMessage] {
    rope.toArray().map(ScribeMessage.init)
  }

  /// Snapshot in wire-type form for the agent loop, which already speaks
  /// `Components.Schemas.ChatMessage`. Package-internal so embedders never
  /// have to touch the OpenAI types.
  package borrowing func snapshotChatMessages() -> [Components.Schemas.ChatMessage] {
    rope.toArray()
  }

  public borrowing func window(from start: Int, count requestedCount: Int) -> [ScribeMessage] {
    rope.window(from: start, count: requestedCount).map(ScribeMessage.init)
  }

  public borrowing func safeForkBoundaries() -> [Int] {
    rope.safeForkBoundaries()
  }

  // MARK: - Mutating ops (sync)

  /// Append messages to the rope and return the index range they occupy.
  ///
  /// Sync — callers that mirror to disk should write through their
  /// ``SessionPersister`` **before** calling this, so a persistence
  /// failure never leaves the rope ahead of disk.
  @discardableResult
  public mutating func append(_ messages: [ScribeMessage]) -> ChangeSet {
    guard !messages.isEmpty else {
      return .appended(range: rope.count..<rope.count)
    }
    let startIndex = rope.count
    for m in messages.toChatMessages() {
      rope.append(m)
    }
    let range = startIndex..<rope.count
    logger.trace(
      "session.doc.append",
      metadata: [
        "added": "\(messages.count)",
        "total": "\(rope.count)",
      ])
    return .appended(range: range)
  }

  /// Replace the rope with `currentMessages[0..<cutAt] + tail` and swap
  /// the doc's identity to `newSessionId` + `newDirectory`. Returns the
  /// resulting ``ChangeSet``.
  ///
  /// Sync — callers that mirror to disk should create the new session
  /// directory + write the new content through their ``SessionPersister``
  /// **before** calling this, so a persistence failure never leaves the
  /// doc pointing at an unwritten session.
  @discardableResult
  public mutating func swapIdentity(
    cutAt: Int,
    tail: [ScribeMessage],
    newSessionId: UUID,
    newDirectory: FilePath,
    reason: ChangeSet.IdentityChangeReason
  ) -> ChangeSet {
    precondition(cutAt >= 0 && cutAt <= rope.count, "swapIdentity cutAt out of bounds")
    let previousSessionId = sessionId
    let currentMessages = rope.toArray().map(ScribeMessage.init)

    let newContent = Array(currentMessages.prefix(cutAt)) + tail
    self.rope = MessageRope(newContent.toChatMessages())
    self.sessionId = newSessionId
    self.directory = newDirectory

    logger.notice(
      "session.doc.swap",
      metadata: [
        "reason": "\(reason)",
        "parent": "\(previousSessionId.uuidString)",
        "child": "\(sessionId.uuidString)",
        "cut_at": "\(cutAt)",
        "tail_messages": "\(tail.count)",
        "new_count": "\(rope.count)",
      ])

    return .identityChanged(
      previousSessionId: previousSessionId,
      sessionId: sessionId,
      directory: directory,
      reason: reason
    )
  }
}
