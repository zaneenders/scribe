import Foundation
import ScribeCore
import Testing

@testable import ScribeKit

protocol ScribeServiceContractFixture: Sendable {

  associatedtype Service: ScribeSessionService

  func makeService() async throws -> Service

  func startBlockedTurn(
    _ service: Service, sessionID: UUID, prompt: String
  ) async throws -> AsyncThrowingStream<ScribeSessionEvent, any Error>

  func finishBlockedTurn(_ service: Service, sessionID: UUID) async throws
}

enum ScribeServiceContractScenarios {

  static func collectEvents(
    from stream: AsyncThrowingStream<ScribeSessionEvent, any Error>
  ) async throws -> [ScribeSessionEvent] {
    var events: [ScribeSessionEvent] = []
    for try await event in stream {
      events.append(event)
    }
    return events
  }

  static func capabilitiesListCreateOpenRoundTrip(
    _ fixture: some ScribeServiceContractFixture
  ) async throws {
    let service = try await fixture.makeService()

    let capabilities = await service.capabilities()
    #expect(capabilities.supportsProfileSwitching)
    #expect(capabilities.supportsFork)
    #expect(capabilities.supportsTLDR)

    let profiles = try await service.listProfiles()
    #expect(profiles.map(\.name).contains("alpha"))
    #expect(profiles.map(\.name).contains("beta"))

    let created = try await service.createSession(
      ScribeCreateSessionRequest(workingDirectory: "/tmp/project", profileName: "alpha"))
    #expect(created.summary.workingDirectory == "/tmp/project")
    #expect(created.summary.profileName == "alpha")
    #expect(created.messages.first?.role == .system)

    let opened = try await service.openSession(id: created.summary.id)
    #expect(opened.summary.id == created.summary.id)
    #expect(opened.messages.map(\.role) == created.messages.map(\.role))

    let listed = try await service.listSessions()
    #expect(listed.map(\.id).contains(created.summary.id))
    #expect(listed.first(where: { $0.id == created.summary.id })?.displayName != nil)
  }

  static func submitStreamsExactlyOneTerminalEventAndPersists(
    _ fixture: some ScribeServiceContractFixture
  ) async throws {
    let service = try await fixture.makeService()
    let session = try await service.createSession(
      ScribeCreateSessionRequest(workingDirectory: "/tmp"))
    let sessionID = session.summary.id

    let events = try await collectEvents(
      from: try await service.submit(
        ScribeSubmitRequest(sessionID: sessionID, prompt: "hello")))

    #expect(events.first == .userPromptAccepted("hello"))
    #expect(events.filter(\.isTerminal).count == 1)
    guard case .turnCompleted(.completed, let messages)? = events.last else {
      Issue.record("Expected terminal completion, got \(events)")
      return
    }
    #expect(messages.first?.role == .system)
    #expect(messages.contains { $0.role == .user && $0.content == "hello" })

    let reopened = try await service.openSession(id: sessionID)
    #expect(reopened.messages.contains { $0.role == .user && $0.content == "hello" })
  }

  static func overlappingSubmitForOneSessionIsRejected(
    _ fixture: some ScribeServiceContractFixture
  ) async throws {
    let service = try await fixture.makeService()
    let session = try await service.createSession(
      ScribeCreateSessionRequest(workingDirectory: "/tmp"))
    let sessionID = session.summary.id

    let blocked = try await fixture.startBlockedTurn(service, sessionID: sessionID, prompt: "first")

    do {
      _ = try await service.submit(ScribeSubmitRequest(sessionID: sessionID, prompt: "second"))
      Issue.record("Expected busy")
    } catch let error as ScribeSessionServiceError {
      #expect(error == .busy(sessionID: sessionID))
    }

    try await fixture.finishBlockedTurn(service, sessionID: sessionID)
    let events = try await collectEvents(from: blocked)
    #expect(events.filter(\.isTerminal).count == 1)

    let next = try await collectEvents(
      from: try await service.submit(ScribeSubmitRequest(sessionID: sessionID, prompt: "again")))
    #expect(next.filter(\.isTerminal).count == 1)
  }

  static func differentSessionsSubmitConcurrently(
    _ fixture: some ScribeServiceContractFixture
  ) async throws {
    let service = try await fixture.makeService()
    let a = try await service.createSession(ScribeCreateSessionRequest(workingDirectory: "/tmp/a"))
    let b = try await service.createSession(ScribeCreateSessionRequest(workingDirectory: "/tmp/b"))

    let blockedA = try await fixture.startBlockedTurn(service, sessionID: a.summary.id, prompt: "a")
    let eventsB = try await collectEvents(
      from: try await service.submit(ScribeSubmitRequest(sessionID: b.summary.id, prompt: "b")))
    #expect(eventsB.filter(\.isTerminal).count == 1)

    try await fixture.finishBlockedTurn(service, sessionID: a.summary.id)
    let eventsA = try await collectEvents(from: blockedA)
    #expect(eventsA.filter(\.isTerminal).count == 1)
  }

  static func interruptEndsActiveTurnAndIsIdempotent(
    _ fixture: some ScribeServiceContractFixture
  ) async throws {
    let service = try await fixture.makeService()
    let session = try await service.createSession(
      ScribeCreateSessionRequest(workingDirectory: "/tmp"))
    let sessionID = session.summary.id

    let blocked = try await fixture.startBlockedTurn(service, sessionID: sessionID, prompt: "hello")
    try await service.interrupt(sessionID: sessionID)
    let events = try await collectEvents(from: blocked)

    #expect(events.filter(\.isTerminal).count == 1)
    guard case .turnCompleted(let outcome, _)? = events.last else {
      Issue.record("Expected terminal completion, got \(events)")
      return
    }
    #expect(outcome == .interrupted)

    try await service.interrupt(sessionID: sessionID)
  }

  static func renameClearAndPinUpdateSummaries(
    _ fixture: some ScribeServiceContractFixture
  ) async throws {
    let service = try await fixture.makeService()
    let session = try await service.createSession(
      ScribeCreateSessionRequest(workingDirectory: "/tmp"))
    let sessionID = session.summary.id

    let renamed = try await service.updatePresentation(
      ScribePresentationUpdate(sessionID: sessionID, name: .set("  Refactor  ")))
    #expect(renamed.name == "Refactor")

    let pinned = try await service.updatePresentation(
      ScribePresentationUpdate(sessionID: sessionID, isPinned: true))
    #expect(pinned.isPinned)
    #expect(pinned.name == "Refactor")

    let cleared = try await service.updatePresentation(
      ScribePresentationUpdate(sessionID: sessionID, name: .cleared))
    #expect(cleared.name == nil)
    #expect(cleared.isPinned)
    #expect(cleared.displayName == String(sessionID.uuidString.prefix(8)).uppercased())

    let second = try await service.createSession(
      ScribeCreateSessionRequest(workingDirectory: "/tmp/other"))
    let renamedSecond = try await service.updatePresentation(
      ScribePresentationUpdate(sessionID: second.summary.id, name: .set("Second")))
    #expect(renamedSecond.name == "Second")

    let listed = try await service.listSessions()
    #expect(listed.first(where: { $0.id == sessionID })?.isPinned == true)
    #expect(listed.first(where: { $0.id == second.summary.id })?.name == "Second")
  }

  static func reconfigureSwitchesProfileAndModel(
    _ fixture: some ScribeServiceContractFixture
  ) async throws {
    let service = try await fixture.makeService()
    let session = try await service.createSession(
      ScribeCreateSessionRequest(workingDirectory: "/tmp", profileName: "alpha"))
    let sessionID = session.summary.id
    #expect(session.summary.model == "model-alpha")

    let reconfigured = try await service.reconfigure(
      ScribeReconfigureSessionRequest(
        sessionID: sessionID, profileName: "beta", reasoningEffort: "xhigh"))
    #expect(reconfigured.summary.profileName == "beta")
    #expect(reconfigured.summary.model == "model-beta")
    #expect(reconfigured.reasoningEffort == "xhigh")
    #expect(reconfigured.profileCatalog.map(\.name).contains("alpha"))
    #expect(reconfigured.profileCatalog.map(\.name).contains("beta"))
    #expect(reconfigured.messages.first?.role == .system)

    let listed = try await service.listSessions()
    #expect(listed.first(where: { $0.id == sessionID })?.model == "model-beta")
    let reopened = try await service.openSession(id: sessionID)
    #expect(reopened.reasoningEffort == "xhigh")

    do {
      _ = try await service.reconfigure(
        ScribeReconfigureSessionRequest(sessionID: sessionID, profileName: "gamma"))
      Issue.record("Expected failure for unknown profile")
    } catch {
    }
  }

  static func forkCreatesNewIdentityKeepingPrefix(
    _ fixture: some ScribeServiceContractFixture
  ) async throws {
    let service = try await fixture.makeService()
    let session = try await service.createSession(
      ScribeCreateSessionRequest(workingDirectory: "/tmp"))
    let sessionID = session.summary.id
    _ = try await collectEvents(
      from: try await service.submit(ScribeSubmitRequest(sessionID: sessionID, prompt: "hello")))

    let opened = try await service.openSession(id: sessionID)
    let messageCount = opened.messages.count
    let forked = try await service.fork(
      ScribeForkSessionRequest(sessionID: sessionID, cutAtMessageIndex: messageCount))
    #expect(forked.summary.id != sessionID)
    #expect(forked.summary.workingDirectory == "/tmp")
    #expect(forked.messages.map(\.role) == opened.messages.map(\.role))
    #expect(!forked.summary.isPinned)

    let listed = try await service.listSessions()
    #expect(listed.map(\.id).contains(sessionID))
    #expect(listed.map(\.id).contains(forked.summary.id))
    let parent = try await service.openSession(id: sessionID)
    #expect(parent.summary.id == sessionID)

    let events = try await collectEvents(
      from: try await service.submit(
        ScribeSubmitRequest(sessionID: forked.summary.id, prompt: "after fork")))
    #expect(events.filter(\.isTerminal).count == 1)
  }

  static func summarizeSplicesRangeIntoNewIdentity(
    _ fixture: some ScribeServiceContractFixture
  ) async throws {
    let service = try await fixture.makeService()
    let session = try await service.createSession(
      ScribeCreateSessionRequest(workingDirectory: "/tmp"))
    let sessionID = session.summary.id
    _ = try await collectEvents(
      from: try await service.submit(ScribeSubmitRequest(sessionID: sessionID, prompt: "hello")))

    let opened = try await service.openSession(id: sessionID)
    let count = opened.messages.count
    let summarized = try await service.summarize(
      ScribeSummarizeSessionRequest(
        sessionID: sessionID, startMessageIndex: 1, endMessageIndex: count))
    #expect(summarized.summary.id != sessionID)
    #expect(summarized.messages.first?.role == .system)
    #expect(summarized.messages.contains { $0.role == .assistant })
    #expect(
      !summarized.messages.contains { $0.role == .user && $0.content == "hello" })

    let reopened = try await service.openSession(id: summarized.summary.id)
    #expect(reopened.summary.id == summarized.summary.id)
    #expect(reopened.messages.count == summarized.messages.count)
  }
}
