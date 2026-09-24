import Foundation
import Logging
import ScribeCore
import SystemPackage

public struct BootstrappedSession: Sendable {
  public let harness: SessionHarness
  public let messageQueue: SessionMessageQueue
  public let initialMessages: [ScribeMessage]
  public let sessionId: UUID
  public let sessionDirectory: FilePath
  public let profile: ScribeProfileSummary
  public let profileCatalog: [ScribeProfileSummary]
  public let reasoningEffort: String?
  public let serviceTier: String?
  public let workingDirectory: String

  public init(
    harness: SessionHarness,
    messageQueue: SessionMessageQueue,
    initialMessages: [ScribeMessage],
    sessionId: UUID,
    sessionDirectory: FilePath,
    profile: ScribeProfileSummary,
    profileCatalog: [ScribeProfileSummary],
    reasoningEffort: String? = nil,
    serviceTier: String? = nil,
    workingDirectory: String
  ) {
    self.harness = harness
    self.messageQueue = messageQueue
    self.initialMessages = initialMessages
    self.sessionId = sessionId
    self.sessionDirectory = sessionDirectory
    self.profile = profile
    self.profileCatalog = profileCatalog
    self.reasoningEffort = reasoningEffort
    self.serviceTier = serviceTier
    self.workingDirectory = workingDirectory
  }
}

public enum ScribeSessionBootstrap {

  public static func open(
    resumeLatest: Bool = false,
    resumeDirectory: FilePath? = nil,
    profileOverride: String? = nil,
    workingDirectory: String = FilePath.currentDirectory.string,
    version: String
  ) async throws -> BootstrappedSession {
    let resolved = try ConfigLoader.resolvePaths()
    let context = ScribeRuntimeContext(
      paths: resolved.paths,
      configurationFile: resolved.configPath,
      defaultWorkingDirectory: workingDirectory,
      version: version)
    return try await open(
      context: context,
      resumeLatest: resumeLatest,
      resumeDirectory: resumeDirectory,
      profileOverride: profileOverride)
  }

  public static func open(
    context: ScribeRuntimeContext,
    resumeLatest: Bool = false,
    resumeDirectory: FilePath? = nil,
    profileOverride: String? = nil
  ) async throws -> BootstrappedSession {
    try await open(
      context: context,
      resumeLatest: resumeLatest,
      resumeDirectory: resumeDirectory,
      profileOverride: profileOverride,
      agentFactory: { configuration, logger in
        try ScribeAgent(configuration: configuration, logger: logger)
      })
  }

  package static func open(
    context: ScribeRuntimeContext,
    resumeLatest: Bool = false,
    resumeDirectory: FilePath? = nil,
    profileOverride: String? = nil,
    agentFactory: @Sendable (ScribeConfig, Logger) throws -> ScribeAgent
  ) async throws -> BootstrappedSession {
    let workingDirectory = context.defaultWorkingDirectory
    let version = context.version
    var loaded = try await ConfigLoader.load(
      paths: context.paths,
      configurationFile: context.configurationFile,
      profileOverride: profileOverride)

    let sessionId: UUID
    let directory: FilePath
    let messages: [ScribeMessage]
    if resumeLatest || resumeDirectory != nil {
      if let resumeDirectory {
        directory = resumeDirectory
      } else {
        directory = try await ChatSessionStore.resolveResumeDirectory(
          specifier: "latest",
          sessionsRoot: loaded.paths.sessionsDirectory,
          preferCWD: workingDirectory)
      }
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

    if profileOverride == nil,
      let profileName = (try? ChatSessionStore.loadMetadata(from: directory))?.profileName,
      profileName != loaded.activeProfileName
    {
      loaded = try await ConfigLoader.load(
        paths: context.paths,
        configurationFile: context.configurationFile,
        profileOverride: profileName)
    }
    let tools = ScribeSystemPrompt.defaultTools()
    let savedEffort =
      profileOverride == nil
      ? try? ChatSessionStore.loadMetadata(from: directory).reasoningEffort
      : nil
    let availableEfforts =
      loaded.profiles.first { $0.name == loaded.activeProfileName }?.reasoningEfforts ?? []
    let effectiveSavedEffort = savedEffort.flatMap { effort in
      availableEfforts.isEmpty || availableEfforts.contains(effort) ? effort : nil
    }
    let savedTier =
      profileOverride == nil
      ? try? ChatSessionStore.loadMetadata(from: directory).serviceTier
      : nil
    let availableTiers =
      loaded.profiles.first { $0.name == loaded.activeProfileName }?.serviceTiers ?? []
    let effectiveSavedTier = savedTier.flatMap { tier in
      availableTiers.contains(tier) ? tier : nil
    }
    let base = loaded.scribeConfig
      .withReasoningEffort(effectiveSavedEffort ?? loaded.scribeConfig.reasoningEffort)
      .withServiceTier(effectiveSavedTier ?? loaded.scribeConfig.serviceTier)
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
      serviceTier: base.serviceTier,
      maxTokens: base.maxTokens,
      sendsOpenCodeHeader: base.sendsOpenCodeHeader,
      temperature: base.temperature,
      maxRetries: base.maxRetries
    )

    let isResuming = resumeLatest || resumeDirectory != nil
    var logger = loaded.makeSessionLogger(sessionId: sessionId)
    logger[metadataKey: "mode"] = isResuming ? "resume" : "new"
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
    let systemPrompt =
      try isNew
      ? ScribeSystemPrompt.load(tools: tools, cwd: workingDirectory, paths: loaded.paths)
      : ""
    let persister = try await FileSessionPersister.open(
      sessionId: sessionId,
      directory: directory,
      sessionCreatedAt: Date(),
      isNewSession: isNew,
      model: configuration.agentModel,
      reasoningEffort: configuration.reasoningEffort,
      serviceTier: configuration.serviceTier,
      profileName: loaded.activeProfileName,
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

    let queue = SessionMessageQueue()
    let agent = try agentFactory(configuration, logger)
    let harness = SessionHarness(
      configuration: configuration,
      document: consume document,
      persister: persister,
      agent: agent,
      logger: logger,
      messageQueue: queue
    )
    let profile =
      loaded.profiles.first { $0.name == loaded.activeProfileName }
      ?? ScribeProfileSummary(
        name: loaded.activeProfileName,
        model: configuration.agentModel,
        baseURL: configuration.serverURL)
    return BootstrappedSession(
      harness: harness,
      messageQueue: queue,
      initialMessages: initialMessages,
      sessionId: sessionId,
      sessionDirectory: directory,
      profile: profile,
      profileCatalog: loaded.profiles,
      reasoningEffort: configuration.reasoningEffort,
      serviceTier: configuration.serviceTier,
      workingDirectory: workingDirectory
    )
  }
}
