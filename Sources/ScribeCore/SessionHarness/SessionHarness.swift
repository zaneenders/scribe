import Foundation
import Logging
import SystemPackage

/// Orchestration layer between embedders and ``ScribeAgent``.
///
/// Owns the paired ``SessionDocument`` and ``SessionPersister``, coordinates
/// turn dispatch, persist-first mutations, and token monitoring. The agent
/// loop stays stateless — history enters as a snapshot and turn diffs are
/// folded back here after persistence succeeds.
///
/// Embedders (TUI, server, tests) call ``submit(_:options:onEvent:)`` for
/// turns and ``applyEdit(_:)`` for fork/summary mutations. Slate-specific
/// UI remains outside this type.
public actor SessionHarness {

  private var document: SessionDocument
  private let persister: any SessionPersister
  private let configuration: ScribeConfig
  private let logger: Logger
  private let agent: ScribeAgent
  private let tokenTracker: TokenTracker

  /// Construct a harness that consumes the sole owner of `document`.
  public init(
    configuration: ScribeConfig,
    document: consuming SessionDocument,
    persister: any SessionPersister,
    logger: Logger
  ) throws {
    self.document = document
    self.persister = persister
    self.configuration = configuration
    self.logger = logger
    self.agent = try ScribeAgent(configuration: configuration, logger: logger)
    self.tokenTracker = TokenTracker(
      contextWindow: configuration.contextWindow,
      threshold: configuration.contextWindowThreshold
    )
  }

  /// Construct a harness with a caller-supplied agent (tests, custom transport).
  init(
    configuration: ScribeConfig,
    document: consuming SessionDocument,
    persister: any SessionPersister,
    agent: ScribeAgent,
    logger: Logger
  ) {
    self.document = document
    self.persister = persister
    self.configuration = configuration
    self.logger = logger
    self.agent = agent
    self.tokenTracker = TokenTracker(
      contextWindow: configuration.contextWindow,
      threshold: configuration.contextWindowThreshold
    )
  }

  // MARK: - Reads

  public var sessionId: UUID { document.sessionId }

  public var sessionDirectory: FilePath { document.directory }

  public var messageCount: Int { document.count }

  public var isEmpty: Bool { document.isEmpty }

  /// Materialise agent history for the current document.
  public func agentHistory() -> [ScribeMessage] {
    document.agentHistory()
  }

  /// Sendable snapshot for cross-isolation reads (picker, transcript replay).
  public func snapshot() -> SessionDocumentSnapshot {
    SessionDocumentSnapshot(
      sessionId: document.sessionId,
      directory: document.directory,
      messages: agentHistory(),
      safeForkBoundaries: document.safeForkBoundaries()
    )
  }

  /// Whether the latest prompt size exceeds the configured threshold.
  public var isApproachingTokenLimit: Bool { tokenTracker.isApproachingLimit }

  /// Whether the latest prompt size exceeds the full context window.
  public var isOverTokenLimit: Bool { tokenTracker.isOverLimit }

  public var lastPromptTokens: Int { tokenTracker.lastPromptTokens }

  // MARK: - Mutations

  /// Apply a session edit with persist-first / commit-second ordering.
  ///
  /// Returns ``SessionIdentityChange`` when the edit forks into a new session.
  @discardableResult
  public func applyEdit(_ op: EditOp) async throws -> SessionIdentityChange? {
    switch op {
    case .append(let messages):
      guard !messages.isEmpty else { return nil }
      try await persister.append(messages)
      document.append(messages)
      return nil

    case .fork(let cutAt, let newSessionId):
      let parentId = document.sessionId
      let newDir = persister.directory(for: newSessionId)
      let successor = document.successor(
        splicing: cutAt..<document.count,
        newSessionId: newSessionId,
        newDirectory: newDir
      )
      try await persister.openSession(
        SessionPersistenceSnapshot(successor),
        parent: SessionParent(sessionId: parentId, forkPoint: cutAt)
      )
      document = successor
      return SessionIdentityChange(
        previousSessionId: parentId,
        newSessionId: newSessionId,
        newDirectory: newDir
      )

    case .forkSplice(let startCut, let endCut, let replacement, let newSessionId):
      let parentId = document.sessionId
      let newDir = persister.directory(for: newSessionId)
      let successor = document.successor(
        splicing: startCut..<endCut,
        inserting: replacement,
        newSessionId: newSessionId,
        newDirectory: newDir
      )
      try await persister.openSession(
        SessionPersistenceSnapshot(successor),
        parent: SessionParent(sessionId: parentId, forkPoint: startCut)
      )
      document = successor
      return SessionIdentityChange(
        previousSessionId: parentId,
        newSessionId: newSessionId,
        newDirectory: newDir
      )
    }
  }

  // MARK: - Turn dispatch

  /// Run one user turn: snapshot history, drive the agent, persist the diff.
  public func submit(
    _ text: String,
    options: AgentRunOptions = AgentRunOptions(),
    onEvent: @Sendable (AgentEvent) -> Void
  ) async throws -> TurnOutcome {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return .completed
    }

    logger.debug(
      "session.harness.submit",
      metadata: ["chars": "\(trimmed.count)"])

    let promptMessages = [ScribeMessage(role: .user, content: trimmed)]
    let history = document.agentHistory()
    let turnStream = agent.run(promptMessages, history: history, options: options)

    for await event in turnStream.events {
      if case .lifecycle(.usage(let usage, _)) = event {
        tokenTracker.accumulate(usage: usage)
      }
      onEvent(event)
    }

    let result = try await turnStream.result.value
    if !result.newMessages.isEmpty {
      try await applyEdit(.append(result.newMessages))
    }

    switch result.outcome {
    case .completed:
      logger.info("session.harness.turn.end", metadata: ["status": "completed"])
      tokenTracker.logStatus(logger: logger)
    case .interrupted:
      logger.notice("session.harness.turn.end", metadata: ["status": "interrupted"])
    case .toolRoundLimit(let max):
      logger.notice(
        "session.harness.turn.end",
        metadata: ["status": "tool-round-limit", "limit": "\(max)"])
      onEvent(.lifecycle(.interrupted))
    }

    return result.outcome
  }

  /// Request interruption of the in-flight agent turn.
  public func interrupt() {
    agent.abort()
  }
}
