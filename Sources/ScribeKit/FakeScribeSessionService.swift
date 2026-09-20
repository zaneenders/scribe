import Foundation
import ScribeCore

/// Scripted behavior for `FakeScribeSessionService` submissions.
public enum FakeSubmitBehavior: Sendable {

  /// A normal turn: the scripted events are emitted, the extra messages are
  /// persisted, and — unless the script already contains a terminal event —
  /// a `.turnCompleted(.completed, …)` terminal event is appended
  /// automatically with the session's persisted messages.
  case turn(events: [ScribeSessionEvent], persisted: [ScribeMessage])

  /// `submit` throws before a stream is produced.
  case failure(ScribeSessionServiceError)

  /// The stream ends without a terminal event (unexpected disconnection).
  case droppedConnection([ScribeSessionEvent])

  /// The stream throws after emitting the scripted events.
  case thrown(events: [ScribeSessionEvent])

  /// The stream emits the scripted events, then waits. Calling
  /// `interrupt(sessionID:)` resumes it with `.interrupted` and a terminal
  /// `.turnCompleted(.interrupted, …)` event.
  case hangUntilInterrupted(events: [ScribeSessionEvent])
}

/// In-memory `ScribeSessionService` for workspace and block tests. Holds
/// sessions, profiles, and scripted submission behavior; never touches the
/// filesystem or the network.
///
/// The fake enforces the service contract: one active submission per session
/// (a second concurrent submission throws `busy`), idempotent interrupts, and
/// exactly one terminal event per successful stream for `turn` scripts.
public actor FakeScribeSessionService: ScribeSessionService {

  public struct SeededSession: Sendable {
    public var summary: ScribeSessionSummary
    public var messages: [ScribeMessage]

    public init(summary: ScribeSessionSummary, messages: [ScribeMessage]) {
      self.summary = summary
      self.messages = messages
    }
  }

  public let capabilitiesValue: ScribeSessionCapabilities

  public let profiles: [ScribeProfileSummary]

  public private(set) var recordedSubmissions: [ScribeSubmitRequest] = []

  public private(set) var interruptedSessionIDs: [UUID] = []

  private var sessions: [UUID: SeededSession] = [:]

  private var submitBehaviors: [UUID: FakeSubmitBehavior] = [:]

  private var defaultSubmitBehavior: FakeSubmitBehavior = .turn(events: [], persisted: [])

  private var activeSubmissions: Set<UUID> = []

  private var interruptWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

  /// Interrupts requested before the turn registered its waiter, so a `hang`
  /// turn never misses an `interrupt` that raced ahead of it.
  private var pendingInterrupts: Set<UUID> = []

  public init(
    capabilities: ScribeSessionCapabilities = ScribeSessionCapabilities(),
    profiles: [ScribeProfileSummary] = [
      ScribeProfileSummary(name: "default", model: "fake-model", baseURL: "http://fake.test")
    ]
  ) {
    self.capabilitiesValue = capabilities
    self.profiles = profiles
  }

  // MARK: - Test scripting

  /// Sets the scripted behavior for one session, or the default behavior for
  /// all sessions when `sessionID` is `nil`.
  public func setSubmitBehavior(
    _ behavior: FakeSubmitBehavior, for sessionID: UUID? = nil
  ) {
    if let sessionID {
      submitBehaviors[sessionID] = behavior
    } else {
      defaultSubmitBehavior = behavior
    }
  }

  /// Inserts a pre-existing session (for resume/list flows).
  @discardableResult
  public func seedSession(
    _ summary: ScribeSessionSummary, messages: [ScribeMessage]
  ) -> ScribeSessionSummary {
    sessions[summary.id] = SeededSession(summary: summary, messages: messages)
    return summary
  }

  /// Persists additional messages into a session (test fixture setup).
  public func appendMessages(_ messages: [ScribeMessage], to sessionID: UUID) throws {
    guard sessions[sessionID] != nil else {
      throw ScribeSessionServiceError.notFound(sessionID: sessionID)
    }
    sessions[sessionID]?.messages.append(contentsOf: messages)
    sessions[sessionID]?.summary.lastMessageAt = Date()
  }

  /// Messages currently held for a session, or `nil` when unknown.
  public func persistedMessages(for sessionID: UUID) -> [ScribeMessage]? {
    sessions[sessionID]?.messages
  }

  // MARK: - ScribeSessionService

  public func capabilities() async -> ScribeSessionCapabilities {
    capabilitiesValue
  }

  public func listSessions() async throws -> [ScribeSessionSummary] {
    sessions.values.map(\.summary).sorted { lhs, rhs in
      if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
      if lhs.lastMessageAt != rhs.lastMessageAt { return lhs.lastMessageAt > rhs.lastMessageAt }
      return lhs.id.uuidString > rhs.id.uuidString
    }
  }

  public func listProfiles() async throws -> [ScribeProfileSummary] {
    profiles
  }

  public func createSession(
    _ request: ScribeCreateSessionRequest
  ) async throws -> ScribeSessionSnapshot {
    let profile = try resolveProfile(named: request.profileName)
    let id = UUID()
    let now = Date()
    let summary = ScribeSessionSummary(
      id: id,
      createdAt: now,
      lastMessageAt: now,
      workingDirectory: request.workingDirectory,
      profileName: profile?.name,
      model: profile?.model ?? "fake-model")
    let session = SeededSession(
      summary: summary,
      messages: [ScribeMessage(role: .system, content: "Fake system prompt.")])
    sessions[id] = session
    return snapshot(for: session)
  }

  public func openSession(id: UUID) async throws -> ScribeSessionSnapshot {
    guard let session = sessions[id] else {
      throw ScribeSessionServiceError.notFound(sessionID: id)
    }
    return snapshot(for: session)
  }

  public func submit(
    _ request: ScribeSubmitRequest
  ) async throws -> AsyncThrowingStream<ScribeSessionEvent, any Error> {
    let sessionID = request.sessionID
    guard sessions[sessionID] != nil else {
      throw ScribeSessionServiceError.notFound(sessionID: sessionID)
    }
    guard !activeSubmissions.contains(sessionID) else {
      throw ScribeSessionServiceError.busy(sessionID: sessionID)
    }
    let prompt = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty else {
      throw ScribeSessionServiceError.invalidRequest("Prompt must not be empty.")
    }
    let behavior = submitBehaviors[sessionID] ?? defaultSubmitBehavior
    if case .failure(let error) = behavior {
      throw error
    }

    recordedSubmissions.append(request)
    activeSubmissions.insert(sessionID)
    sessions[sessionID]?.messages.append(ScribeMessage(role: .user, content: prompt))
    sessions[sessionID]?.summary.lastMessageAt = Date()

    return AsyncThrowingStream { continuation in
      let task = Task {
        await self.runStream(
          sessionID: sessionID,
          prompt: prompt,
          behavior: behavior,
          continuation: continuation)
      }
      continuation.onTermination = { _ in
        task.cancel()
      }
    }
  }

  public func interrupt(sessionID: UUID) async throws {
    guard sessions[sessionID] != nil else {
      throw ScribeSessionServiceError.notFound(sessionID: sessionID)
    }
    interruptedSessionIDs.append(sessionID)
    if activeSubmissions.contains(sessionID) {
      pendingInterrupts.insert(sessionID)
    }
    interruptWaiters.removeValue(forKey: sessionID)?.resume()
  }

  public func updatePresentation(
    _ request: ScribePresentationUpdate
  ) async throws -> ScribeSessionSummary {
    guard var session = sessions[request.sessionID] else {
      throw ScribeSessionServiceError.notFound(sessionID: request.sessionID)
    }
    switch request.name {
    case .unchanged:
      break
    case .set(let proposed):
      let trimmed = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
      session.summary.name = trimmed.isEmpty ? nil : trimmed
    case .cleared:
      session.summary.name = nil
    }
    if let isPinned = request.isPinned {
      session.summary.isPinned = isPinned
    }
    sessions[request.sessionID] = session
    return session.summary
  }

  public func reconfigure(
    _ request: ScribeReconfigureSessionRequest
  ) async throws -> ScribeSessionSnapshot {
    guard capabilitiesValue.supportsProfileSwitching else {
      throw ScribeSessionServiceError.unsupported(feature: "profile switching")
    }
    guard var session = sessions[request.sessionID] else {
      throw ScribeSessionServiceError.notFound(sessionID: request.sessionID)
    }
    guard let profile = profiles.first(where: { $0.name == request.profileName }) else {
      throw ScribeSessionServiceError.invalidRequest(
        "Unknown profile `\(request.profileName)`.")
    }
    session.summary.profileName = profile.name
    session.summary.model = profile.model
    sessions[request.sessionID] = session
    return snapshot(for: session)
  }

  public func fork(
    _ request: ScribeForkSessionRequest
  ) async throws -> ScribeSessionSnapshot {
    guard capabilitiesValue.supportsFork else {
      throw ScribeSessionServiceError.unsupported(feature: "fork")
    }
    guard let parent = sessions[request.sessionID] else {
      throw ScribeSessionServiceError.notFound(sessionID: request.sessionID)
    }
    guard request.cutAtMessageIndex >= 0, request.cutAtMessageIndex <= parent.messages.count
    else {
      throw ScribeSessionServiceError.invalidRequest(
        "Fork cut index \(request.cutAtMessageIndex) is out of range.")
    }
    let newID = UUID()
    let now = Date()
    let summary = ScribeSessionSummary(
      id: newID,
      createdAt: now,
      lastMessageAt: now,
      workingDirectory: parent.summary.workingDirectory,
      profileName: parent.summary.profileName,
      model: parent.summary.model)
    let child = SeededSession(
      summary: summary,
      messages: Array(parent.messages.prefix(request.cutAtMessageIndex)))
    sessions[newID] = child
    return snapshot(for: child)
  }

  public func summarize(
    _ request: ScribeSummarizeSessionRequest
  ) async throws -> ScribeSessionSnapshot {
    guard capabilitiesValue.supportsTLDR else {
      throw ScribeSessionServiceError.unsupported(feature: "TLDR")
    }
    guard let parent = sessions[request.sessionID] else {
      throw ScribeSessionServiceError.notFound(sessionID: request.sessionID)
    }
    let count = parent.messages.count
    guard request.startMessageIndex >= 0, request.endMessageIndex <= count,
      request.startMessageIndex < request.endMessageIndex
    else {
      throw ScribeSessionServiceError.invalidRequest(
        "TLDR range \(request.startMessageIndex)..<\(request.endMessageIndex) is invalid.")
    }
    let newID = UUID()
    let now = Date()
    let summary = ScribeSessionSummary(
      id: newID,
      createdAt: now,
      lastMessageAt: now,
      workingDirectory: parent.summary.workingDirectory,
      profileName: parent.summary.profileName,
      model: request.model ?? parent.summary.model)
    let summaryMessage = ScribeMessage(
      role: .assistant,
      content: "TLDR summary of messages \(request.startMessageIndex)..<\(request.endMessageIndex).")
    var messages = Array(parent.messages.prefix(request.startMessageIndex))
    messages.append(summaryMessage)
    messages.append(contentsOf: parent.messages.suffix(count - request.endMessageIndex))
    let child = SeededSession(summary: summary, messages: messages)
    sessions[newID] = child
    return snapshot(for: child)
  }

  // MARK: - Stream execution

  private enum StreamFailure: Error, Sendable {
    case unexpectedDisconnection
  }

  private func runStream(
    sessionID: UUID,
    prompt: String,
    behavior: FakeSubmitBehavior,
    continuation: AsyncThrowingStream<ScribeSessionEvent, any Error>.Continuation
  ) async {
    defer {
      activeSubmissions.remove(sessionID)
      interruptWaiters.removeValue(forKey: sessionID)
      pendingInterrupts.remove(sessionID)
      continuation.finish()
    }
    continuation.yield(.userPromptAccepted(prompt))
    switch behavior {
    case .failure:
      // Unreachable: failure is thrown from `submit` before streaming.
      return
    case .turn(let events, let persisted):
      for event in events { continuation.yield(event) }
      if !persisted.isEmpty {
        sessions[sessionID]?.messages.append(contentsOf: persisted)
        sessions[sessionID]?.summary.lastMessageAt = Date()
      }
      if !events.contains(where: \.isTerminal) {
        if let messages = sessions[sessionID]?.messages {
          continuation.yield(.turnCompleted(.completed, messages: messages))
        } else {
          continuation.yield(.turnFailed("Session disappeared during the turn."))
        }
      }
    case .droppedConnection(let events):
      for event in events { continuation.yield(event) }
    case .thrown(let events):
      for event in events { continuation.yield(event) }
      continuation.finish(throwing: StreamFailure.unexpectedDisconnection)
      return
    case .hangUntilInterrupted(let events):
      for event in events { continuation.yield(event) }
      if pendingInterrupts.remove(sessionID) == nil {
        await withTaskCancellationHandler {
          await withCheckedContinuation { waiter in
            interruptWaiters[sessionID] = waiter
          }
        } onCancel: {
          Task { await self.resumeInterruptWaiter(sessionID: sessionID) }
        }
      }
      continuation.yield(.interrupted)
      if let messages = sessions[sessionID]?.messages {
        continuation.yield(.turnCompleted(.interrupted, messages: messages))
      } else {
        continuation.yield(.turnFailed("Session disappeared during the turn."))
      }
    }
  }

  /// Resumes a stream waiting for `interrupt` so task cancellation cannot
  /// strand the actor method.
  func resumeInterruptWaiter(sessionID: UUID) {
    interruptWaiters.removeValue(forKey: sessionID)?.resume()
  }

  // MARK: - Helpers

  private func resolveProfile(
    named name: String?
  ) throws -> ScribeProfileSummary? {
    guard let name else { return profiles.first }
    guard let profile = profiles.first(where: { $0.name == name }) else {
      throw ScribeSessionServiceError.invalidRequest("Unknown profile `\(name)`.")
    }
    return profile
  }

  private func snapshot(for session: SeededSession) -> ScribeSessionSnapshot {
    ScribeSessionSnapshot(
      summary: session.summary,
      messages: session.messages,
      profileCatalog: profiles)
  }
}
