import Foundation
import Logging
import ScribeLLM
import SystemPackage

// MARK: - SessionDocument

/// The single source of truth for a chat session.
///
/// Owns a ``MessageRope`` of messages, the session identity (id +
/// on-disk directory), and a ``SessionPersister`` that mirrors mutations
/// to durable storage. Every mutation flows through ``apply(_:)`` so
/// rope + persister + observers stay in lock-step.
///
/// `SessionDocument` is an actor; both the agent loop (appending
/// per-turn) and the chat host (issuing `/fork` and `/tldr` ops) hold
/// references and mutate concurrently. Observers receive ``ChangeSet``
/// events via ``changes()`` and use them to refresh views.
public actor SessionDocument {

  // MARK: - Identity

  public private(set) var sessionId: UUID
  public private(set) var directory: FilePath

  // MARK: - Truth

  private var rope: MessageRope
  private let persister: any SessionPersister
  private let logger: Logger

  // MARK: - Observers

  /// Keyed by observer id so removal is O(1). Continuations are finished
  /// when the doc deinits or when an observer cancels its stream task.
  private var observerContinuations: [UUID: AsyncStream<ChangeSet>.Continuation] = [:]

  // MARK: - Init

  /// Open a document over an in-memory ``MessageRope`` seeded with
  /// `initialMessages`.
  ///
  /// - Parameters:
  ///   - sessionId: Session UUID (matches the on-disk directory name).
  ///   - directory: Session directory (`sessions/{uuid}`). Used for
  ///     identity tracking and the resume-hint at exit; the persister is
  ///     what actually reads/writes inside this path.
  ///   - initialMessages: Pre-loaded transcript. For new sessions this is
  ///     `[ScribeMessage(role: .system, content: prompt)]`. For resumed
  ///     sessions it's whatever the caller restored from disk.
  ///   - persister: Backing store. CLI passes a JSONL-backed persister;
  ///     embedders may use ``InMemorySessionPersister``.
  ///   - logger: Session logger; the doc emits `session.doc.*` events for
  ///     each applied op.
  public init(
    sessionId: UUID,
    directory: FilePath,
    initialMessages: [ScribeMessage],
    persister: any SessionPersister,
    logger: Logger
  ) {
    self.sessionId = sessionId
    self.directory = directory
    self.rope = MessageRope(initialMessages.toChatMessages())
    self.persister = persister
    self.logger = logger
  }

  deinit {
    for cont in observerContinuations.values { cont.finish() }
  }

  // MARK: - Reading

  public var count: Int { rope.count }

  public var isEmpty: Bool { rope.isEmpty }

  /// Materialise the whole transcript. O(n). Prefer ``window(from:count:)``
  /// when the caller only needs a viewport.
  public func snapshot() -> [ScribeMessage] {
    rope.toArray().map(ScribeMessage.init)
  }

  /// Snapshot in wire-type form for the agent loop, which already speaks
  /// `Components.Schemas.ChatMessage`. Package-internal so embedders never
  /// have to touch the OpenAI types.
  package func snapshotChatMessages() -> [Components.Schemas.ChatMessage] {
    rope.toArray()
  }

  public func window(from start: Int, count requestedCount: Int) -> [ScribeMessage] {
    rope.window(from: start, count: requestedCount).map(ScribeMessage.init)
  }

  public func safeForkBoundaries() -> [Int] {
    rope.safeForkBoundaries()
  }

  // MARK: - Observation

  /// Subscribe to ``ChangeSet`` events. The returned stream finishes when
  /// the document deinits. Callers that want to stop early should cancel
  /// the consuming `Task`; the doc cleans up the continuation when the
  /// stream is torn down.
  public func changes() -> AsyncStream<ChangeSet> {
    let id = UUID()
    let (stream, continuation) = AsyncStream<ChangeSet>.makeStream()
    observerContinuations[id] = continuation
    continuation.onTermination = { [weak self] _ in
      guard let self else { return }
      Task { await self.removeObserver(id: id) }
    }
    return stream
  }

  private func removeObserver(id: UUID) {
    observerContinuations.removeValue(forKey: id)
  }

  private func emit(_ change: ChangeSet) {
    for cont in observerContinuations.values { cont.yield(change) }
  }

  // MARK: - Applying ops

  /// Apply a mutation to the document. Updates the rope, persists the
  /// change, and emits a ``ChangeSet`` to all subscribers before
  /// returning.
  ///
  /// Mutations are atomic from the perspective of subscribers — the rope
  /// and the persister both reflect the new state before the
  /// ``ChangeSet`` event is yielded. A persistence failure aborts the op
  /// (the rope is rolled back) and rethrows.
  @discardableResult
  public func apply(_ op: EditOp) async throws -> ChangeSet {
    switch op {
    case .append(let messages):
      return try await applyAppend(messages)

    case .fork(let cutAt, let newSessionId):
      return try await applyFork(cutAt: cutAt, tail: [], newSessionId: newSessionId, reason: .fork)

    case .forkSplice(let startCut, let endCut, let replacement, let newSessionId):
      // forkSplice = cut at startCut + replacement + tail beyond endCut.
      // The persister gets the full new content via cutAt + tail; the doc
      // computes the tail from its current rope.
      precondition(startCut <= endCut, "forkSplice startCut > endCut")
      precondition(endCut <= rope.count, "forkSplice endCut out of bounds")
      let currentArray = rope.toArray().map(ScribeMessage.init)
      let tail = replacement + Array(currentArray[endCut..<currentArray.count])
      return try await applyFork(
        cutAt: startCut,
        tail: tail,
        newSessionId: newSessionId,
        reason: .forkSplice
      )
    }
  }

  // MARK: - Apply helpers

  private func applyAppend(_ messages: [ScribeMessage]) async throws -> ChangeSet {
    guard !messages.isEmpty else {
      return .appended(range: rope.count..<rope.count)
    }
    let startIndex = rope.count
    // Mutate rope first (cheap, in-memory); persistence next.
    for m in messages.toChatMessages() {
      rope.append(m)
    }
    do {
      try await persister.append(messages)
    } catch {
      // Roll back the in-memory append so observers never see a state
      // that didn't get persisted.
      rope.truncate(to: startIndex)
      throw error
    }
    let range = startIndex..<rope.count
    logger.trace(
      "session.doc.append",
      metadata: [
        "added": "\(messages.count)",
        "total": "\(rope.count)",
      ])
    let change = ChangeSet.appended(range: range)
    emit(change)
    return change
  }

  private func applyFork(
    cutAt: Int,
    tail: [ScribeMessage],
    newSessionId: UUID,
    reason: ChangeSet.IdentityChangeReason
  ) async throws -> ChangeSet {
    precondition(cutAt >= 0 && cutAt <= rope.count, "fork cutAt out of bounds")
    let previousSessionId = sessionId
    let currentMessages = rope.toArray().map(ScribeMessage.init)

    let result = try await persister.fork(
      cutAt: cutAt,
      tail: tail,
      currentMessages: currentMessages,
      newSessionId: newSessionId,
      parentSessionId: previousSessionId
    )

    // Rebuild the rope to match the new session content.
    let newContent = Array(currentMessages.prefix(cutAt)) + tail
    self.rope = MessageRope(newContent.toChatMessages())
    self.sessionId = result.sessionId
    self.directory = result.directory

    logger.notice(
      "session.doc.fork",
      metadata: [
        "reason": "\(reason)",
        "parent": "\(previousSessionId.uuidString)",
        "child": "\(sessionId.uuidString)",
        "cut_at": "\(cutAt)",
        "tail_messages": "\(tail.count)",
        "new_count": "\(rope.count)",
      ])

    let change = ChangeSet.identityChanged(
      previousSessionId: previousSessionId,
      sessionId: sessionId,
      directory: directory,
      reason: reason
    )
    emit(change)
    return change
  }
}
