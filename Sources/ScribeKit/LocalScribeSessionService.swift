import Foundation
import Logging
import ScribeCore
import SystemPackage

/// Actor-owned local `ScribeSessionService`. Adapts the existing runtime —
/// `ScribeSessionBootstrap`, `SessionHarness`, `ChatSessionStore`, and
/// `FileSessionPersister` — behind the transport-neutral contract, driven
/// entirely by an explicit `ScribeRuntimeContext` (no environment or current
/// directory access).
///
/// Responsibilities:
/// - list metadata without loading agents;
/// - lazily bootstrap an existing session by UUID;
/// - own at most one loaded runtime per session ID;
/// - reject overlapping direct submissions for one session (`busy`);
/// - map `AgentEvent`/`TurnOutcome` through `ScribeAgentEventMapper`;
/// - persist before emitting terminal success;
/// - update rename/pin metadata for loaded and unloaded sessions;
/// - reconfigure profiles and return refreshed snapshots;
/// - carry identity changes through fork and TLDR, re-keying the runtime cache;
/// - allow idle runtime caches to be discarded without affecting persisted
///   sessions.
public actor LocalScribeSessionService: ScribeSessionService {

  private struct LoadedSession {
    let boot: BootstrappedSession
    var profileCatalog: [ScribeProfileSummary]
  }

  private let context: ScribeRuntimeContext

  private let agentFactory: @Sendable (ScribeConfig, Logger) throws -> ScribeAgent

  private var runtimes: [UUID: LoadedSession] = [:]

  private var activeSubmissions: Set<UUID> = []

  private var activeEdits: Set<UUID> = []

  private var loadingSessions: Set<UUID> = []

  /// Resumed when the active submission for a session releases its slot, so
  /// `interrupt` can return only once the turn has fully ended.
  private var submissionCompletionWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

  private let capabilitiesValue = ScribeSessionCapabilities()

  public init(context: ScribeRuntimeContext) {
    self.init(
      context: context,
      agentFactory: { configuration, logger in
        try ScribeAgent(configuration: configuration, logger: logger)
      })
  }

  /// Init with an injected agent factory (used by tests to script turns
  /// without network access).
  package init(
    context: ScribeRuntimeContext,
    agentFactory: @Sendable @escaping (ScribeConfig, Logger) throws -> ScribeAgent
  ) {
    self.context = context
    self.agentFactory = agentFactory
  }

  // MARK: - ScribeSessionService

  public func capabilities() async -> ScribeSessionCapabilities {
    capabilitiesValue
  }

  public func listSessions() async throws -> [ScribeSessionSummary] {
    try await perform {
      let directories = try await ChatSessionStore.listSessionDirectories(
        sessionsRoot: self.context.paths.sessionsDirectory)
      return try directories.map { directory in
        let metadata = try ChatSessionStore.loadMetadata(from: directory)
        return self.summary(for: metadata, directory: directory)
      }
    }
  }

  public func listProfiles() async throws -> [ScribeProfileSummary] {
    try await perform {
      try await self.loadConfiguration().profiles
    }
  }

  public func createSession(
    _ request: ScribeCreateSessionRequest
  ) async throws -> ScribeSessionSnapshot {
    try await perform {
      let boot = try await self.bootstrap(
        workingDirectory: request.workingDirectory,
        profileOverride: request.profileName,
        resumeDirectory: nil)
      let metadata = try ChatSessionStore.loadMetadata(from: boot.sessionDirectory)
      let snapshot = ScribeSessionSnapshot(
        summary: self.summary(for: metadata, directory: boot.sessionDirectory),
        messages: boot.initialMessages,
        profileCatalog: boot.profileCatalog)
      self.runtimes[boot.sessionId] = LoadedSession(boot: boot, profileCatalog: boot.profileCatalog)
      return snapshot
    }
  }

  public func openSession(id: UUID) async throws -> ScribeSessionSnapshot {
    try await perform {
      guard !self.activeEdits.contains(id) else {
        throw ScribeSessionServiceError.busy(sessionID: id)
      }
      return try await self.snapshot(of: self.loadedSession(for: id))
    }
  }

  public func submit(
    _ request: ScribeSubmitRequest
  ) async throws -> AsyncThrowingStream<ScribeSessionEvent, any Error> {
    let sessionID = request.sessionID
    try guardIdle(sessionID)
    let prompt = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty else {
      throw ScribeSessionServiceError.invalidRequest("Prompt must not be empty.")
    }
    activeSubmissions.insert(sessionID)
    do {
      let loaded = try await loadedSession(for: sessionID)
      let harness = loaded.boot.harness
      return AsyncThrowingStream { continuation in
        let task = Task {
          await self.runTurn(
            sessionID: sessionID,
            harness: harness,
            prompt: prompt,
            continuation: continuation)
        }
        continuation.onTermination = { _ in
          task.cancel()
        }
      }
    } catch let error as ScribeSessionServiceError {
      endSubmission(sessionID: sessionID)
      throw error
    } catch {
      endSubmission(sessionID: sessionID)
      throw ScribeSessionServiceError.failed(
        ScribeAgentEventMapper.failureMessage(for: error))
    }
  }

  public func interrupt(sessionID: UUID) async throws {
    try await perform {
      if self.activeEdits.contains(sessionID) {
        throw ScribeSessionServiceError.busy(sessionID: sessionID)
      }
      guard let loaded = self.runtimes[sessionID] else {
        // Nothing is running for an unloaded session; still surface unknown IDs.
        guard self.sessionExists(sessionID) else {
          throw ScribeSessionServiceError.notFound(sessionID: sessionID)
        }
        return
      }
      guard self.activeSubmissions.contains(sessionID) else { return }
      await loaded.boot.harness.interrupt()
      // Wait for the turn to release its slot so callers observe a session that
      // already accepts the next submission (e.g. fork/reconfigure) after await.
      guard self.activeSubmissions.contains(sessionID) else { return }
      await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
        self.submissionCompletionWaiters[sessionID] = waiter
      }
    }
  }

  public func updatePresentation(
    _ request: ScribePresentationUpdate
  ) async throws -> ScribeSessionSummary {
    try await perform {
      let directory =
        self.runtimes[request.sessionID]?.boot.sessionDirectory
        ?? self.context.paths.sessionDirectory(sessionId: request.sessionID)
      guard FileStat.stat(directory.appendingPathComponent("metadata.json")).exists else {
        throw ScribeSessionServiceError.notFound(sessionID: request.sessionID)
      }
      let name: String?
      switch request.name {
      case .unchanged: name = nil
      case .set(let proposed): name = proposed
      case .cleared: name = ""
      }
      let metadata = try await ChatSessionStore.updatePresentation(
        in: directory, name: name, isPinned: request.isPinned)
      return self.summary(for: metadata, directory: directory)
    }
  }

  public func reconfigure(
    _ request: ScribeReconfigureSessionRequest
  ) async throws -> ScribeSessionSnapshot {
    try await perform {
      guard self.capabilitiesValue.supportsProfileSwitching else {
        throw ScribeSessionServiceError.unsupported(feature: "profile switching")
      }
      try self.guardIdle(request.sessionID)
      self.activeEdits.insert(request.sessionID)
      defer { self.activeEdits.remove(request.sessionID) }
      let loaded: LoadedSession
      if let cached = self.runtimes[request.sessionID] {
        loaded = cached
      } else {
        loaded = try await self.loadedSession(for: request.sessionID)
      }

      let loadedConfig = try await self.loadConfiguration(profileOverride: request.profileName)
      let base = loadedConfig.scribeConfig
      let harness = loaded.boot.harness
      let workingDirectory = loaded.boot.workingDirectory
      let newConfig = ScribeConfig(
        agentModel: base.agentModel,
        contextWindow: base.contextWindow,
        contextWindowThreshold: base.contextWindowThreshold,
        serverURL: base.serverURL,
        apiKey: base.apiKey,
        apiType: loadedConfig.apiType,
        tools: ScribeSystemPrompt.defaultTools(),
        workingDirectory: workingDirectory,
        reasoningEnabled: base.reasoningEnabled,
        reasoningEffort: base.reasoningEffort,
        serviceTier: base.serviceTier,
        maxTokens: base.maxTokens,
        sendsOpenCodeHeader: base.sendsOpenCodeHeader,
        temperature: base.temperature,
        maxRetries: base.maxRetries
      )
      try await harness.reconfigure(
        configuration: newConfig, profileName: loadedConfig.activeProfileName,
        agentFactory: self.agentFactory)
      var updated = loaded
      updated.profileCatalog = loadedConfig.profiles
      self.runtimes[request.sessionID] = updated
      return try await self.snapshot(of: updated)
    }
  }

  public func fork(
    _ request: ScribeForkSessionRequest
  ) async throws -> ScribeSessionSnapshot {
    try await perform {
      guard self.capabilitiesValue.supportsFork else {
        throw ScribeSessionServiceError.unsupported(feature: "fork")
      }
      try self.guardIdle(request.sessionID)
      self.activeEdits.insert(request.sessionID)
      defer { self.activeEdits.remove(request.sessionID) }
      let loaded = try await self.loadedSession(for: request.sessionID)

      let harness = loaded.boot.harness
      let document = await harness.snapshot()
      guard document.safeForkBoundaries.contains(request.cutAtMessageIndex) else {
        throw ScribeSessionServiceError.invalidRequest(
          "Cut index \(request.cutAtMessageIndex) is not a safe fork boundary.")
      }
      let newSessionID = UUID()
      guard
        let change = try await harness.applyEdit(
          .fork(cutAt: request.cutAtMessageIndex, newSessionId: newSessionID))
      else {
        throw ScribeSessionServiceError.failed("Fork did not produce a new session.")
      }
      let successor = self.rekey(loaded, from: request.sessionID, to: change)
      return try await self.snapshot(of: successor)
    }
  }

  public func summarize(
    _ request: ScribeSummarizeSessionRequest
  ) async throws -> ScribeSessionSnapshot {
    try await perform {
      guard self.capabilitiesValue.supportsTLDR else {
        throw ScribeSessionServiceError.unsupported(feature: "TLDR")
      }
      try self.guardIdle(request.sessionID)
      self.activeEdits.insert(request.sessionID)
      defer { self.activeEdits.remove(request.sessionID) }
      let loaded = try await self.loadedSession(for: request.sessionID)

      let harness = loaded.boot.harness
      let document = await harness.snapshot()
      let count = document.messages.count
      guard request.startMessageIndex >= 0, request.endMessageIndex <= count,
        request.startMessageIndex < request.endMessageIndex
      else {
        throw ScribeSessionServiceError.invalidRequest(
          "TLDR range \(request.startMessageIndex)..<\(request.endMessageIndex) is invalid.")
      }
      let configuration = await harness.configurationSnapshot()
      let result = try await SessionSummarizer.summarize(
        slice: Array(document.messages[request.startMessageIndex..<request.endMessageIndex]),
        configuration: configuration,
        model: request.model,
        sessionId: request.sessionID,
        logger: Logger(label: "scribe.service.tldr"),
        agentFactory: self.agentFactory)
      let audit = ScribeMessage(
        role: .system,
        content:
          "TLDR audit\nModel: \(result.model)\nSystem prompt:\n\(result.systemPrompt)\nUser prompt:\n\(result.userPrompt)"
      )
      let replacement = [
        audit,
        ScribeMessage(role: .assistant, content: result.summary),
      ]
      let newSessionID = UUID()
      guard
        let change = try await harness.applyEdit(
          .forkSplice(
            startCut: request.startMessageIndex,
            endCut: request.endMessageIndex,
            replacement: replacement,
            newSessionId: newSessionID))
      else {
        throw ScribeSessionServiceError.failed("TLDR did not produce a new session.")
      }
      let successor = self.rekey(loaded, from: request.sessionID, to: change)
      return try await self.snapshot(of: successor)
    }
  }

  // MARK: - Runtime cache management

  /// Discards the loaded runtime cache for a session. The persisted session is
  /// unaffected and can be reopened later. Active submissions are kept.
  public func discardRuntime(sessionID: UUID) {
    guard !activeSubmissions.contains(sessionID), !activeEdits.contains(sessionID),
      !loadingSessions.contains(sessionID) else { return }
    runtimes[sessionID] = nil
  }

  // MARK: - Turn execution

  private func runTurn(
    sessionID: UUID,
    harness: SessionHarness,
    prompt: String,
    continuation: AsyncThrowingStream<ScribeSessionEvent, any Error>.Continuation
  ) async {
    do {
      let previousMessageCount = await harness.snapshot().messages.count
      let outcome = try await harness.submit(
        prompt,
        onUserPrompt: { text in
          continuation.yield(.userPromptAccepted(text))
        },
        onEvent: { event in
          if let mapped = ScribeAgentEventMapper.map(event) {
            continuation.yield(mapped)
          }
        })
      // The harness persists completed turn messages before `submit` returns,
      // so persistence precedes the terminal event.
      let document = await harness.snapshot()
      // Release the submission slot before the terminal event so consumers see
      // a session that already accepts the next turn.
      endSubmission(sessionID: sessionID)
      // A stream that ends without any assistant text is an unexpected
      // disconnection, not a completed turn.
      if case .completed = outcome, Self.assistantText(in: Array(document.messages.dropFirst(previousMessageCount))).isEmpty {
        continuation.yield(.turnFailed("No assistant response."))
      } else {
        continuation.yield(
          .turnCompleted(ScribeAgentEventMapper.map(outcome), messages: document.messages))
      }
      continuation.finish()
    } catch {
      endSubmission(sessionID: sessionID)
      continuation.yield(.turnFailed(ScribeAgentEventMapper.failureMessage(for: error)))
      continuation.finish()
    }
  }

  private static func assistantText(in messages: [ScribeMessage]) -> String {
    guard let last = messages.last(where: { $0.role == .assistant }) else { return "" }
    return last.content.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func endSubmission(sessionID: UUID) {
    activeSubmissions.remove(sessionID)
    submissionCompletionWaiters.removeValue(forKey: sessionID)?.resume()
  }

  // MARK: - Bootstrap and cache

  private func bootstrap(
    workingDirectory: String?,
    profileOverride: String?,
    resumeDirectory: FilePath?
  ) async throws -> BootstrappedSession {
    var context = self.context
    if let workingDirectory {
      context.defaultWorkingDirectory = workingDirectory
    } else if let resumeDirectory,
      let saved = try? ChatSessionStore.loadMetadata(from: resumeDirectory).cwd,
      !saved.isEmpty
    {
      // Resuming must continue in the session's own directory, not the host's
      // default. Otherwise a reopened session silently runs somewhere else.
      context.defaultWorkingDirectory = saved
    }
    return try await ScribeSessionBootstrap.open(
      context: context,
      resumeDirectory: resumeDirectory,
      profileOverride: profileOverride,
      agentFactory: agentFactory)
  }

  private func cache(_ boot: BootstrappedSession) -> LoadedSession {
    let loaded = LoadedSession(boot: boot, profileCatalog: boot.profileCatalog)
    runtimes[boot.sessionId] = loaded
    return loaded
  }

  private func loadedSession(for sessionID: UUID) async throws -> LoadedSession {
    if let cached = runtimes[sessionID] { return cached }
    guard !loadingSessions.contains(sessionID) else {
      throw ScribeSessionServiceError.busy(sessionID: sessionID)
    }
    loadingSessions.insert(sessionID)
    defer { loadingSessions.remove(sessionID) }
    let boot = try await bootstrap(
      workingDirectory: nil,
      profileOverride: nil,
      resumeDirectory: try existingSessionDirectory(for: sessionID))
    if let cached = runtimes[sessionID] { return cached }
    return cache(boot)
  }

  /// Re-keys the runtime cache after a fork/TLDR identity change; the harness
  /// document now represents the successor session.
  private func rekey(
    _ loaded: LoadedSession, from previousID: UUID, to change: SessionIdentityChange
  ) -> LoadedSession {
    runtimes[previousID] = nil
    runtimes[change.newSessionId] = loaded
    return loaded
  }

  private func existingSessionDirectory(for sessionID: UUID) throws -> FilePath {
    let directory = context.paths.sessionDirectory(sessionId: sessionID)
    let metadataPath = directory.appendingPathComponent("metadata.json")
    guard FileStat.stat(metadataPath).exists else {
      throw ScribeSessionServiceError.notFound(sessionID: sessionID)
    }
    return directory
  }

  private func sessionExists(_ sessionID: UUID) -> Bool {
    let directory = context.paths.sessionDirectory(sessionId: sessionID)
    return FileStat.stat(directory.appendingPathComponent("metadata.json")).exists
  }

  private func guardIdle(_ sessionID: UUID) throws {
    guard !activeSubmissions.contains(sessionID), !activeEdits.contains(sessionID) else {
      throw ScribeSessionServiceError.busy(sessionID: sessionID)
    }
  }

  // MARK: - Snapshots and summaries

  private func snapshot(of loaded: LoadedSession) async throws -> ScribeSessionSnapshot {
    let harness = loaded.boot.harness
    let document = await harness.snapshot()
    let directory = await harness.sessionDirectory
    let metadata = try ChatSessionStore.loadMetadata(from: directory)
    return ScribeSessionSnapshot(
      summary: summary(for: metadata, directory: directory),
      messages: document.messages,
      profileCatalog: loaded.profileCatalog)
  }

  private func summary(
    for metadata: ChatSessionMetadata, directory: FilePath
  ) -> ScribeSessionSummary {
    ScribeSessionSummary(
      id: metadata.id,
      name: metadata.name,
      isPinned: metadata.isPinned,
      createdAt: metadata.createdAt,
      lastMessageAt: ChatSessionStore.lastMessageDate(in: directory, metadata: metadata),
      workingDirectory: metadata.cwd,
      profileName: metadata.profileName,
      model: metadata.model)
  }

  private func loadConfiguration(
    profileOverride: String? = nil
  ) async throws -> LoadedConfig {
    try await ConfigLoader.load(
      paths: context.paths,
      configurationFile: context.configurationFile,
      profileOverride: profileOverride)
  }

  /// Wraps thrown errors into display-safe service errors at the API boundary.
  private func perform<T>(_ body: () async throws -> T) async throws -> T {
    do {
      return try await body()
    } catch let error as ScribeSessionServiceError {
      throw error
    } catch {
      throw ScribeSessionServiceError.failed(
        ScribeAgentEventMapper.failureMessage(for: error))
    }
  }
}
