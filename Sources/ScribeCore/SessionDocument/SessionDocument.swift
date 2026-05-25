import Foundation
import Logging
import ScribeLLM
import SystemPackage

/// The single source of truth for a chat session's messages and identity.
///
/// Owns a ``MessageRope`` and the session identity (id + on-disk
/// directory). `SessionDocument` is `~Copyable`: the compiler enforces a
/// single owner (typically ``SessionHarness``). All reads are synchronous borrows via
/// subscript and `count`; all mutations are synchronous and take
/// `inout self` (append) or produce a successor (fork / tldr).
///
/// Message arrays are not part of the public surface — callers access
/// content by index. Arrays appear only at I/O boundaries (incoming user
/// input, agent output, disk wire format) via package helpers.
///
/// Persistence is **not** the doc's concern. The owner pairs the doc
/// with a ``SessionPersister`` and orchestrates the two — write to disk
/// first, then commit the in-memory change here, so a persistence
/// failure never leaves the rope ahead of disk.
public struct SessionDocument: ~Copyable {

  public private(set) var sessionId: UUID
  public private(set) var directory: FilePath

  private var rope: MessageRope
  private let logger: Logger

  /// Open an empty document for a session identity.
  ///
  /// Content enters through ``append(_:)`` (incoming user input, agent
  /// output, or hydration from disk at an I/O boundary in the owner).
  public init(
    sessionId: UUID,
    directory: FilePath,
    logger: Logger
  ) {
    self.sessionId = sessionId
    self.directory = directory
    self.rope = MessageRope()
    self.logger = logger
  }

  private init(
    sessionId: UUID,
    directory: FilePath,
    rope: MessageRope,
    logger: Logger
  ) {
    self.sessionId = sessionId
    self.directory = directory
    self.rope = rope
    self.logger = logger
  }

  public var count: Int { rope.count }

  public var isEmpty: Bool { rope.isEmpty }

  /// O(log n) random access to a single message.
  public subscript(index: Int) -> ScribeMessage {
    ScribeMessage(rope[index])
  }

  public borrowing func safeForkBoundaries() -> [Int] {
    rope.safeForkBoundaries()
  }

  /// Materialise the transcript for the agent loop. Package-internal —
  /// embedders pass the result to ``ScribeAgent/run(_:history:)``.
  package borrowing func agentHistory() -> [ScribeMessage] {
    var out: [ScribeMessage] = []
    out.reserveCapacity(count)
    for i in 0..<count {
      out.append(self[i])
    }
    return out
  }

  /// Wire-type snapshot for transports that speak OpenAI chat messages.
  package borrowing func chatMessages() -> [Components.Schemas.ChatMessage] {
    rope.toArray()
  }

  /// Append incoming messages to the rope and return the index range they occupy.
  ///
  /// Sync — callers that mirror to disk should write through their
  /// ``SessionPersister`` **before** calling this, so a persistence
  /// failure never leaves the rope ahead of disk.
  @discardableResult
  public mutating func append(_ messages: [ScribeMessage]) -> Range<Int> {
    guard !messages.isEmpty else {
      return rope.count..<rope.count
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
    return range
  }

  /// Build a successor document by splicing `range` with `replacement`.
  ///
  /// Borrowing — the original doc is intact, so the owner can persist
  /// the successor first and only assign it (`self = successor`) if
  /// persistence succeeds.
  public borrowing func successor(
    splicing range: Range<Int>,
    inserting replacement: [ScribeMessage] = [],
    newSessionId: UUID,
    newDirectory: FilePath
  ) -> SessionDocument {
    precondition(range.lowerBound >= 0 && range.upperBound <= count, "successor splice out of bounds")
    var newRope = rope
    newRope.splice(range, with: replacement.toChatMessages())
    logger.notice(
      "session.doc.successor",
      metadata: [
        "splice": "\(range.lowerBound)..<\(range.upperBound)",
        "replacement_messages": "\(replacement.count)",
        "child": "\(newSessionId.uuidString)",
        "new_count": "\(newRope.count)",
      ])
    return SessionDocument(
      sessionId: newSessionId,
      directory: newDirectory,
      rope: newRope,
      logger: logger
    )
  }
}
