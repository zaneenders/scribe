import Foundation
import Logging
import ScribeCodexAuth
import ScribeCore
import ScribeLLM
import Synchronization
import SystemPackage
import Testing
@testable import ScribeKit

struct CodexProviderPropagationTests {
  @Test func factoryIsPreservedThroughCreateReconfigureForkAndSummary() async throws {
    try await withLocalServiceFixture { fixture in
      let factories = Mutex(0)
      let client = Client(serverURL: URL(string: "http://test")!, transport: fixture.transport)
      let service = LocalScribeSessionService(context: fixture.context, agentFactory: { configuration, logger in
        factories.withLock { $0 += 1 }
        return ScribeAgent(client: client, model: configuration.agentModel,
          workingDirectory: FilePath(configuration.workingDirectory), reasoningEnabled: nil, logger: logger)
      })
      let created = try await service.createSession(.init(workingDirectory: "/tmp"))
      #expect(factories.withLock { $0 } == 1)
      _ = try await service.reconfigure(.init(sessionID: created.summary.id, profileName: "beta"))
      #expect(factories.withLock { $0 } == 2)
      _ = try await ScribeServiceContractScenarios.collectEvents(from: try await service.submit(.init(sessionID: created.summary.id, prompt: "hello")))
      let opened = try await service.openSession(id: created.summary.id)
      let fork = try await service.fork(.init(sessionID: created.summary.id, cutAtMessageIndex: opened.messages.count))
      _ = try await service.summarize(.init(sessionID: fork.summary.id, startMessageIndex: 1, endMessageIndex: fork.messages.count))
      #expect(factories.withLock { $0 } >= 3)
    }
  }

@Test func bootstrapRetainsInjectedProviderAfterReconfiguration() async throws {
  try await withLocalServiceFixture { fixture in
    try ConfigLoader.upsertCodexProfile(at: fixture.context.paths.profileManifestPath)
    let provider = DeniedProvider()
    let opened = try await ScribeSessionBootstrap.open(
      context: fixture.context, profileOverride: "codex", codexCredentials: provider)
    _ = try await opened.harness.submit("hello", onEvent: { _ in })
    #expect(await provider.calls > 0)
    let before = await provider.calls
    let loaded = try await ConfigLoader.load(paths: fixture.context.paths,
      configurationFile: fixture.context.configurationFile, profileOverride: "codex")
    try await opened.harness.reconfigure(configuration: loaded.scribeConfig, profileName: "codex")
    _ = try await opened.harness.submit("again", onEvent: { _ in })
    #expect(await provider.calls > before)
  }
}

  @Test func injectedAccessOnlyProviderReachesAgentsAfterReconfiguration() async throws {
    try await withLocalServiceFixture { fixture in
      try ConfigLoader.upsertCodexProfile(at: fixture.context.paths.profileManifestPath)
      let provider = DeniedProvider()
      let service = LocalScribeSessionService(context: fixture.context, codexCredentials: provider)
      let created = try await service.createSession(.init(workingDirectory: "/tmp", profileName: "codex"))
      _ = try await ScribeServiceContractScenarios.collectEvents(from: try await service.submit(.init(sessionID: created.summary.id, prompt: "hello")))
      #expect(await provider.calls > 0)
      let before = await provider.calls
      _ = try await service.reconfigure(.init(sessionID: created.summary.id, profileName: "codex"))
      _ = try await ScribeServiceContractScenarios.collectEvents(from: try await service.submit(.init(sessionID: created.summary.id, prompt: "again")))
      #expect(await provider.calls > before)
    }
  }
}

private actor DeniedProvider: CodexAccessCredentialProvider {
  private(set) var calls = 0
  func credential(rejectingAccessToken: String?) async throws -> CodexAccessCredential {
    calls += 1
    throw CodexAuthorityError.denied
  }
}
