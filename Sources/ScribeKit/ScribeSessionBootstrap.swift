import Foundation
import Logging
import ScribeCore
import SystemPackage

/// A fully initialized session suitable for a graphical or terminal front end.
public struct BootstrappedSession: Sendable {
  public let harness: SessionHarness
  public let messageQueues: SessionMessageQueues
  public let initialMessages: [ScribeMessage]
  public let sessionId: UUID
  public let sessionDirectory: FilePath
  public let profile: ProfileSummary
  public let profileCatalog: [ProfileSummary]
  public let workingDirectory: String

  public init(
    harness: SessionHarness,
    messageQueues: SessionMessageQueues,
    initialMessages: [ScribeMessage],
    sessionId: UUID,
    sessionDirectory: FilePath,
    profile: ProfileSummary,
    profileCatalog: [ProfileSummary],
    workingDirectory: String
  ) {
    self.harness = harness
    self.messageQueues = messageQueues
    self.initialMessages = initialMessages
    self.sessionId = sessionId
    self.sessionDirectory = sessionDirectory
    self.profile = profile
    self.profileCatalog = profileCatalog
    self.workingDirectory = workingDirectory
  }
}

/// Shared session construction for non-CLI front ends.
public enum ScribeSessionBootstrap {
  public static func open(
    resumeLatest: Bool = false,
    profileOverride: String? = nil,
    workingDirectory: String = FilePath.currentDirectory.string,
    version: String
  ) async throws -> BootstrappedSession {
    let loaded = try await ConfigLoader.load(profileOverride: profileOverride)
    let tools = ScribeSystemPrompt.defaultTools()
    let systemPrompt = ScribeSystemPrompt.make(tools: tools, cwd: workingDirectory)
    let base = loaded.scribeConfig
    let configuration = ScribeConfig(
      agentModel: base.agentModel,
      contextWindow: base.contextWindow,
      contextWindowThreshold: base.contextWindowThreshold,
      serverURL: base.serverURL,
      apiKey: base.apiKey,
      apiType: loaded.apiType,
      tools: tools,
      workingDirectory: workingDirectory,
      reasoningEnabled: base.reasoningEnabled,
      reasoningEffort: base.reasoningEffort,
      maxTokens: base.maxTokens
    )

    let sessionId: UUID
    let directory: FilePath
    let messages: [ScribeMessage]
    if resumeLatest {
      directory = try await ChatSessionStore.resolveResumeDirectory(
        specifier: "latest",
        sessionsRoot: loaded.paths.sessionsDirectory,
        preferCWD: workingDirectory
      )
      let metadata = try ChatSessionStore.loadMetadata(from: directory)
      sessionId = metadata.id
      messages = try ChatSessionStore.loadMessages(from: directory)
      guard messages.first?.role == .system else {
        throw ScribeError.sessionCorrupted(
          reason: "Resumed conversation must begin with a system message.")
      }
    } else {
      sessionId = UUID()
      directory = try await ChatSessionStore.sessionDirectory(
        sessionId: sessionId,
        sessionsRoot: loaded.paths.sessionsDirectory
      )
      messages = []
    }

    var logger = loaded.makeSessionLogger(sessionId: sessionId)
    logger[metadataKey: "mode"] = resumeLatest ? "resume" : "new"
    logger.notice(
      "chat.session.start",
      metadata: [
        "scribe_version": "\(version)",
        "model": "\(configuration.agentModel)",
        "cwd": "\(workingDirectory)",
        "profile": "\(loaded.activeProfileName)",
        "frontend": "macos",
      ])

    let isNew = messages.isEmpty
    let persister = try await FileSessionPersister.open(
      sessionId: sessionId,
      directory: directory,
      sessionCreatedAt: Date(),
      isNewSession: isNew,
      model: configuration.agentModel,
      cwd: workingDirectory,
      baseURL: configuration.serverURL,
      scribeVersion: version,
      logger: logger
    )
    var document = SessionDocument(sessionId: sessionId, directory: directory, logger: logger)
    var initialMessages = messages
    if isNew {
      let system = ScribeMessage(role: .system, content: systemPrompt)
      try await persister.append([system])
      document.append([system])
      initialMessages = [system]
    } else {
      document.append(messages)
    }

    let queues = SessionMessageQueues()
    let harness = try SessionHarness(
      configuration: configuration,
      document: consume document,
      persister: persister,
      logger: logger,
      messageQueues: queues
    )
    let profile = loaded.profiles.first { $0.name == loaded.activeProfileName }
      ?? ProfileSummary(
        name: loaded.activeProfileName,
        model: configuration.agentModel,
        baseURL: configuration.serverURL)
    return BootstrappedSession(
      harness: harness,
      messageQueues: queues,
      initialMessages: initialMessages,
      sessionId: sessionId,
      sessionDirectory: directory,
      profile: profile,
      profileCatalog: loaded.profiles,
      workingDirectory: workingDirectory
    )
  }
}
