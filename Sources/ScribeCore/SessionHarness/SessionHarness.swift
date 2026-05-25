import Foundation
import Logging
import SystemPackage

public actor SessionHarness {

  private var document: SessionDocument
  private let persister: any SessionPersister
  private let configuration: ScribeConfig
  private let logger: Logger
  private let agent: ScribeAgent
  private let tokenTracker: TokenTracker
  private let messageQueues: SessionMessageQueues

  public init(
    configuration: ScribeConfig,
    document: consuming SessionDocument,
    persister: any SessionPersister,
    logger: Logger,
    messageQueues: SessionMessageQueues = SessionMessageQueues()
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
    self.messageQueues = messageQueues
  }

  init(
    configuration: ScribeConfig,
    document: consuming SessionDocument,
    persister: any SessionPersister,
    agent: ScribeAgent,
    logger: Logger,
    messageQueues: SessionMessageQueues = SessionMessageQueues()
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
    self.messageQueues = messageQueues
  }

  public var sessionId: UUID { document.sessionId }

  public var sessionDirectory: FilePath { document.directory }

  public var messageCount: Int { document.count }

  public var isEmpty: Bool { document.isEmpty }

  public func agentHistory() -> [ScribeMessage] {
    document.agentHistory()
  }

  public func snapshot() -> SessionDocumentSnapshot {
    SessionDocumentSnapshot(
      sessionId: document.sessionId,
      directory: document.directory,
      messages: agentHistory(),
      safeForkBoundaries: document.safeForkBoundaries()
    )
  }

  public var isApproachingTokenLimit: Bool { tokenTracker.isApproachingLimit }

  public var isOverTokenLimit: Bool { tokenTracker.isOverLimit }

  public var lastPromptTokens: Int { tokenTracker.lastPromptTokens }

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

  public func submit(
    _ text: String,
    options: AgentRunOptions = AgentRunOptions(),
    onUserPrompt: @Sendable (String) -> Void = { _ in },
    onEvent: @Sendable (AgentEvent) -> Void
  ) async throws -> TurnOutcome {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return .completed
    }

    var outcome = try await runTurn(
      promptMessages: [ScribeMessage(role: .user, content: trimmed)],
      options: options,
      onUserPrompt: onUserPrompt,
      onEvent: onEvent
    )

    while true {
      let steering = messageQueues.drainSteering()
      if !steering.isEmpty {
        outcome = try await runTurn(
          promptMessages: steering,
          options: options,
          onUserPrompt: onUserPrompt,
          onEvent: onEvent,
          queueKind: .steering
        )
        continue
      }

      guard outcome == .completed else {
        return outcome
      }

      let followUp = messageQueues.drainFollowUp()
      if followUp.isEmpty {
        return outcome
      }

      outcome = try await runTurn(
        promptMessages: followUp,
        options: options,
        onUserPrompt: onUserPrompt,
        onEvent: onEvent,
        queueKind: .followUp
      )
    }
  }

  private func runTurn(
    promptMessages: [ScribeMessage],
    options: AgentRunOptions,
    onUserPrompt: @Sendable (String) -> Void,
    onEvent: @Sendable (AgentEvent) -> Void,
    queueKind: MessageQueueKind? = nil
  ) async throws -> TurnOutcome {
    guard !promptMessages.isEmpty else { return .completed }

    for msg in promptMessages where msg.role == .user {
      onUserPrompt(msg.content)
    }

    let charCount = promptMessages.reduce(0) { $0 + $1.content.count }
    var metadata: Logger.Metadata = ["chars": "\(charCount)", "messages": "\(promptMessages.count)"]
    if let queueKind {
      metadata["queue"] = "\(queueKind)"
    }
    logger.debug("session.harness.submit", metadata: metadata)

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

  public func interrupt() {
    agent.abort()
  }
}
