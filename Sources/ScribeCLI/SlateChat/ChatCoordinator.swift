import Foundation
import Logging
import ScribeCore
import ScribeLLM
import Synchronization

// MARK: - Model turn interrupt flag

/// Cooperative abort for Ctrl+C during an assistant/tool round without
/// cancelling the long-lived coordinator task.
final class ModelTurnInterruptFlag: Sendable {
  private let lock = Mutex(false)

  init() {}

  func clear() { lock.withLock { $0 = false } }
  func request() { lock.withLock { $0 = true } }
  func peek() -> Bool { lock.withLock { $0 } }

  func logState(_ logger: Logger, tag: String) {
    let val = peek()
    logger.trace("chat.interrupt-flag.\(tag)", metadata: ["value": "\(val)"])
  }
}

// MARK: - Host event channel

/// Events the coordinator task sends to the host for rendering.
enum HostEvent: Sendable {
  case transcript(TranscriptEvent)
  case modelTurnRunning(Bool)
  case coordinatorFinished
}

// MARK: - Coordinator result

struct CoordinatorResult {
  let finalMessageCount: Int
  let reason: StopReason
}

enum StopReason: Sendable {
  case eof
  case exitCommand
  case error(Error)
}

extension StopReason: Equatable {
  static func == (lhs: StopReason, rhs: StopReason) -> Bool {
    switch (lhs, rhs) {
    case (.eof, .eof): return true
    case (.exitCommand, .exitCommand): return true
    case (.error, .error): return true
    default: return false
    }
  }
}

// MARK: - ChatCoordinator

/// Coordinates the chat loop: reads user input, runs agent turns,
/// persists sessions, and emits events to the host.
///
/// Owns the ScribeAgent and TokenTracker. Communicates with the host
/// exclusively through an AsyncStream of input lines and a closure
/// that sinks HostEvent values.
actor ChatCoordinator {
  private let agent: ScribeAgent
  private let persistence: SessionPersistence
  private let eventSink: (HostEvent) -> Void
  private let log: Logger
  private let contextWindow: Int
  private let contextWindowThreshold: Double
  private let agentModel: String
  private let serverURL: String

  /// Initialize with everything the coordinator needs.
  init(
    configuration: ScribeConfig,
    systemPrompt: String,
    initialMessages: [Components.Schemas.ChatMessage],
    persistence: SessionPersistence,
    eventSink: @escaping @Sendable (HostEvent) -> Void,
    log: Logger
  ) throws {
    self.persistence = persistence
    self.eventSink = eventSink
    self.log = log
    self.contextWindow = configuration.contextWindow
    self.contextWindowThreshold = configuration.contextWindowThreshold
    self.agentModel = configuration.agentModel
    self.serverURL = configuration.serverURL

    let resolvedMessages: [Components.Schemas.ChatMessage]
    if !initialMessages.isEmpty {
      guard initialMessages.first?.role == .system else {
        throw ScribeError.sessionCorrupted(
          reason: "Resumed conversation must begin with a system message.")
      }
      resolvedMessages = initialMessages
    } else {
      resolvedMessages = [.init(role: .system, content: systemPrompt)]
    }

    self.agent = try ScribeAgent(
      configuration: configuration,
      systemPrompt: systemPrompt,
      initialMessages: resolvedMessages
    )
  }

  /// Test-only initializer that takes a pre-built agent.
  package init(
    agent: ScribeAgent,
    persistence: SessionPersistence,
    eventSink: @escaping @Sendable (HostEvent) -> Void,
    log: Logger,
    contextWindow: Int,
    contextWindowThreshold: Double,
    agentModel: String,
    serverURL: String
  ) {
    self.agent = agent
    self.persistence = persistence
    self.eventSink = eventSink
    self.log = log
    self.contextWindow = contextWindow
    self.contextWindowThreshold = contextWindowThreshold
    self.agentModel = agentModel
    self.serverURL = serverURL
  }

  // MARK: - Run loop

  /// Run the prompt loop. Reads lines from `input` until nil (EOF) or
  /// "exit". Returns a result with the final message count and stop reason.
  ///
  /// - Parameter interruptFlag: Cooperative abort flag checked before each
  ///   HTTP call and tool invocation.
  func run(
    input: AsyncStream<String>,
    interruptFlag: ModelTurnInterruptFlag
  ) async -> CoordinatorResult {
    let initialMessages = await agent.messages
    let isNewSession =
      initialMessages.count <= 1
      && initialMessages.allSatisfy({ $0.role == .system })

    // Write metadata for new sessions.
    if isNewSession {
      let cwd = FileManager.default.currentDirectoryPath
      _ = try? await persistence.writeMetadataOnce(
        model: agentModel,
        cwd: cwd,
        baseURL: serverURL)
    }

    // Persist initial messages.
    try? await persistence.append(initialMessages)
    var persistedCount = initialMessages.count

    let msgCount = initialMessages.count
    log.debug(
      "event=chat.coordinator.start messages=\(msgCount) resumed=\(!isNewSession)")

    let tracker = TokenTracker(
      contextWindow: contextWindow,
      threshold: contextWindowThreshold
    )

    var reason: StopReason = .eof
    for await rawLine in input {
      let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed == "exit" {
        log.notice("event=chat.user.exit-command")
        reason = .exitCommand
        break
      }
      if trimmed.isEmpty {
        log.trace("event=chat.user.empty-skip")
        continue
      }

      // Record user submission into transcript.
      eventSink(.transcript(.userSubmitted(trimmed)))
      log.debug("event=agent.turn.dispatch chars=\(trimmed.count)")

      interruptFlag.clear()
      interruptFlag.logState(log, tag: "cleared-for-new-turn")
      eventSink(.modelTurnRunning(true))
      defer { eventSink(.modelTurnRunning(false)) }

      let options = AgentRunOptions(
        shouldAbortTurn: {
          let v = interruptFlag.peek()
          if v { self.log.trace("chat.interrupt-flag.polled", metadata: ["value": "true"]) }
          return v
        }
      )

      do {
        let ts = await agent.prompt(trimmed, options: options, log: log)
        for await event in ts.events {
          if case .usage(let usage, _) = event { tracker.accumulate(usage: usage) }
          eventSink(.transcript(event))
        }
        let result = try await ts.result.value
        switch result.outcome {
        case .completed:
          log.info("event=agent.turn.end status=completed")
          tracker.logStatus(logger: log)
        case .interrupted:
          log.notice("event=agent.turn.end status=interrupted")
          eventSink(.transcript(.turnInterrupted))
        case .toolRoundLimit(let max):
          log.notice("event=agent.turn.end status=tool-round-limit limit=\(max)")
          eventSink(.transcript(.turnInterrupted))
        }
      } catch {
        let se = (error as? ScribeError) ?? .generic(String(describing: error))
        log.error(
          "event=agent.turn.end status=error err=\"\(se.errorDescription ?? String(describing: se))\"")
        eventSink(.transcript(.harnessError(se)))
      }

      await persistNew(since: persistedCount)
      persistedCount = await agent.messages.count

      // Turn complete — tell host to finalize and optionally
      // compare streaming render against the batch render.
      let committed = await agent.messages
      eventSink(.transcript(.turnComplete(referenceMessages: committed)))
    }

    await persistNew(since: persistedCount)
    let finalMsgCount = await agent.messages.count
    log.debug("event=chat.coordinator.end transcript_messages=\(finalMsgCount)")
    return CoordinatorResult(finalMessageCount: finalMsgCount, reason: reason)
  }

  // MARK: - Persistence helper

  private func persistNew(since count: Int) async {
    let newMessages = await agent.messages(since: count)
    guard !newMessages.isEmpty else { return }
    do {
      try await persistence.append(newMessages)
      let total = await agent.messages.count
      log.trace(
        "chat.persist.append",
        metadata: [
          "new": "\(newMessages.count)",
          "total": "\(total)",
        ])
    } catch {
      log.error(
        "chat.persist.fail",
        metadata: [
          "err": "\(error.localizedDescription)"
        ])
    }
  }
}
