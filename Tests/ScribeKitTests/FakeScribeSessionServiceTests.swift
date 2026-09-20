import Foundation
import ScribeCore
import Testing

@testable import ScribeKit

@Suite
struct FakeScribeSessionServiceTests {

  private func collectEvents(
    from stream: AsyncThrowingStream<ScribeSessionEvent, any Error>
  ) async throws -> [ScribeSessionEvent] {
    var events: [ScribeSessionEvent] = []
    for try await event in stream {
      events.append(event)
    }
    return events
  }

  @Test func capabilitiesAndProfileListing() async throws {
    let service = FakeScribeSessionService(
      capabilities: ScribeSessionCapabilities(supportsFork: false),
      profiles: [ScribeProfileSummary(name: "alpha", model: "m-a", baseURL: "http://a")])

    let capabilities = await service.capabilities()
    #expect(capabilities.supportsProfileSwitching)
    #expect(!capabilities.supportsFork)

    let profiles = try await service.listProfiles()
    #expect(profiles.map(\.name) == ["alpha"])
  }

  @Test func createOpenAndListSessions() async throws {
    let service = FakeScribeSessionService()
    let created = try await service.createSession(
      ScribeCreateSessionRequest(workingDirectory: "/tmp/project", profileName: "default"))

    #expect(created.messages.first?.role == .system)
    #expect(created.summary.workingDirectory == "/tmp/project")
    #expect(created.summary.profileName == "default")
    #expect(!created.profileCatalog.isEmpty)

    let opened = try await service.openSession(id: created.summary.id)
    #expect(opened == created)

    let listed = try await service.listSessions()
    #expect(listed.map(\.id) == [created.summary.id])
  }

  @Test func openUnknownSessionThrowsNotFound() async throws {
    let service = FakeScribeSessionService()
    let missing = UUID()
    do {
      _ = try await service.openSession(id: missing)
      Issue.record("Expected notFound")
    } catch let error as ScribeSessionServiceError {
      #expect(error == .notFound(sessionID: missing))
    }
  }

  @Test func submitEmitsUserPromptEventsAndExactlyOneTerminal() async throws {
    let service = FakeScribeSessionService()
    let session = try await service.createSession(
      ScribeCreateSessionRequest(workingDirectory: "/tmp"))
    let sessionID = session.summary.id

    let reply = ScribeMessage(role: .assistant, content: "hi there")
    await service.setSubmitBehavior(
      .turn(
        events: [
          .sectionStarted(.answer),
          .sectionTextAppended(.answer, text: "hi there"),
        ],
        persisted: [reply]))

    let events = try await collectEvents(
      from: try await service.submit(ScribeSubmitRequest(sessionID: sessionID, prompt: "hello")))

    #expect(events.first == .userPromptAccepted("hello"))
    #expect(events.filter(\.isTerminal).count == 1)
    guard case .turnCompleted(.completed, let messages)? = events.last else {
      Issue.record("Expected terminal completion, got \(events)")
      return
    }
    #expect(messages.map(\.role) == [.system, .user, .assistant])
    #expect(messages.last?.content == "hi there")
    #expect(await service.persistedMessages(for: sessionID)?.count == 3)
    #expect(await service.recordedSubmissions.map(\.prompt) == ["hello"])
  }

  @Test func scriptWithExplicitTerminalIsNotDoubleTerminated() async throws {
    let service = FakeScribeSessionService()
    let session = try await service.createSession(
      ScribeCreateSessionRequest(workingDirectory: "/tmp"))
    await service.setSubmitBehavior(
      .turn(
        events: [.turnCompleted(.interrupted, messages: [ScribeMessage(role: .system, content: "s")])],
        persisted: []))

    let events = try await collectEvents(
      from: try await service.submit(ScribeSubmitRequest(sessionID: session.summary.id, prompt: "x")))

    #expect(events.filter(\.isTerminal).count == 1)
  }

  @Test func overlappingSubmissionsForOneSessionAreRejectedAsBusy() async throws {
    let service = FakeScribeSessionService()
    let session = try await service.createSession(
      ScribeCreateSessionRequest(workingDirectory: "/tmp"))
    let sessionID = session.summary.id
    await service.setSubmitBehavior(.hangUntilInterrupted(events: []), for: sessionID)

    let first = try await service.submit(ScribeSubmitRequest(sessionID: sessionID, prompt: "first"))

    do {
      _ = try await service.submit(ScribeSubmitRequest(sessionID: sessionID, prompt: "second"))
      Issue.record("Expected busy")
    } catch let error as ScribeSessionServiceError {
      #expect(error == .busy(sessionID: sessionID))
    }

    try await service.interrupt(sessionID: sessionID)
    var events: [ScribeSessionEvent] = []
    var iterator = first.makeAsyncIterator()
    while let event = try await iterator.next() {
      events.append(event)
    }
    #expect(events.first == .userPromptAccepted("first"))
    #expect(events.contains(.interrupted))
    #expect(events.filter(\.isTerminal).count == 1)
    #expect(await service.interruptedSessionIDs == [sessionID])

    // After the turn ends, the session accepts submissions again.
    await service.setSubmitBehavior(.turn(events: [], persisted: []), for: sessionID)
    let second = try await collectEvents(
      from: try await service.submit(ScribeSubmitRequest(sessionID: sessionID, prompt: "again")))
    #expect(second.filter(\.isTerminal).count == 1)
  }

  @Test func differentSessionsSubmitConcurrently() async throws {
    let service = FakeScribeSessionService()
    let a = try await service.createSession(ScribeCreateSessionRequest(workingDirectory: "/tmp/a"))
    let b = try await service.createSession(ScribeCreateSessionRequest(workingDirectory: "/tmp/b"))
    await service.setSubmitBehavior(.hangUntilInterrupted(events: []), for: a.summary.id)

    let streamA = try await service.submit(ScribeSubmitRequest(sessionID: a.summary.id, prompt: "a"))
    // Session B is unaffected by A's active turn and completes normally.
    let eventsB = try await collectEvents(
      from: try await service.submit(ScribeSubmitRequest(sessionID: b.summary.id, prompt: "b")))
    #expect(eventsB.filter(\.isTerminal).count == 1)

    try await service.interrupt(sessionID: a.summary.id)
    let eventsA = try await collectEvents(from: streamA)
    #expect(eventsA.filter(\.isTerminal).count == 1)
  }

  @Test func interruptIsIdempotent() async throws {
    let service = FakeScribeSessionService()
    let session = try await service.createSession(
      ScribeCreateSessionRequest(workingDirectory: "/tmp"))
    try await service.interrupt(sessionID: session.summary.id)
    try await service.interrupt(sessionID: session.summary.id)
    #expect(await service.interruptedSessionIDs.count == 2)
  }

  @Test func blankPromptIsAnInvalidRequest() async throws {
    let service = FakeScribeSessionService()
    let session = try await service.createSession(
      ScribeCreateSessionRequest(workingDirectory: "/tmp"))
    do {
      _ = try await service.submit(ScribeSubmitRequest(sessionID: session.summary.id, prompt: "  \n "))
      Issue.record("Expected invalidRequest")
    } catch let error as ScribeSessionServiceError {
      guard case .invalidRequest = error else {
        Issue.record("Expected invalidRequest, got \(error)")
        return
      }
    }
  }

  @Test func droppedConnectionEndsWithoutTerminalEvent() async throws {
    let service = FakeScribeSessionService()
    let session = try await service.createSession(
      ScribeCreateSessionRequest(workingDirectory: "/tmp"))
    await service.setSubmitBehavior(.droppedConnection([.sectionStarted(.answer)]))

    let events = try await collectEvents(
      from: try await service.submit(ScribeSubmitRequest(sessionID: session.summary.id, prompt: "x")))

    #expect(!events.isEmpty)
    #expect(events.filter(\.isTerminal).isEmpty)
  }

  @Test func thrownBehaviorThrowsMidStream() async throws {
    let service = FakeScribeSessionService()
    let session = try await service.createSession(
      ScribeCreateSessionRequest(workingDirectory: "/tmp"))
    await service.setSubmitBehavior(.thrown(events: [.sectionStarted(.answer)]))

    var sawEvent = false
    do {
      for try await _ in try await service.submit(
        ScribeSubmitRequest(sessionID: session.summary.id, prompt: "x"))
      {
        sawEvent = true
      }
      Issue.record("Expected stream to throw")
    } catch {
      #expect(sawEvent)
    }
  }

  @Test func presentationUpdatesRenameClearAndPin() async throws {
    let service = FakeScribeSessionService()
    let session = try await service.createSession(
      ScribeCreateSessionRequest(workingDirectory: "/tmp"))
    let id = session.summary.id

    let renamed = try await service.updatePresentation(
      ScribePresentationUpdate(sessionID: id, name: .set("  Refactor  ")))
    #expect(renamed.name == "Refactor")

    let pinned = try await service.updatePresentation(
      ScribePresentationUpdate(sessionID: id, isPinned: true))
    #expect(pinned.isPinned)
    #expect(pinned.name == "Refactor")

    let cleared = try await service.updatePresentation(
      ScribePresentationUpdate(sessionID: id, name: .cleared))
    #expect(cleared.name == nil)
    #expect(cleared.isPinned)
    #expect(cleared.displayName == String(id.uuidString.prefix(8)).uppercased())

    let clearedViaWhitespace = try await service.updatePresentation(
      ScribePresentationUpdate(sessionID: id, name: .set("   ")))
    #expect(clearedViaWhitespace.name == nil)
  }

  @Test func reconfigureSwitchesProfileAndModel() async throws {
    let service = FakeScribeSessionService(
      profiles: [
        ScribeProfileSummary(name: "alpha", model: "m-a", baseURL: "http://a"),
        ScribeProfileSummary(name: "beta", model: "m-b", baseURL: "http://b"),
      ])
    let session = try await service.createSession(
      ScribeCreateSessionRequest(workingDirectory: "/tmp", profileName: "alpha"))
    let id = session.summary.id

    let reconfigured = try await service.reconfigure(
      ScribeReconfigureSessionRequest(sessionID: id, profileName: "beta"))
    #expect(reconfigured.summary.profileName == "beta")
    #expect(reconfigured.summary.model == "m-b")
    #expect(reconfigured.profileCatalog.map(\.name) == ["alpha", "beta"])

    do {
      _ = try await service.reconfigure(
        ScribeReconfigureSessionRequest(sessionID: id, profileName: "gamma"))
      Issue.record("Expected invalidRequest")
    } catch let error as ScribeSessionServiceError {
      guard case .invalidRequest = error else {
        Issue.record("Expected invalidRequest, got \(error)")
        return
      }
    }
  }

  @Test func forkCreatesNewIdentityWithPrefixMessages() async throws {
    let service = FakeScribeSessionService()
    let session = try await service.createSession(
      ScribeCreateSessionRequest(workingDirectory: "/tmp"))
    let id = session.summary.id
    try await service.appendMessages(
      [
        ScribeMessage(role: .user, content: "one"),
        ScribeMessage(role: .assistant, content: "two"),
        ScribeMessage(role: .user, content: "three"),
      ],
      to: id)

    let forked = try await service.fork(ScribeForkSessionRequest(sessionID: id, cutAtMessageIndex: 3))
    #expect(forked.summary.id != id)
    #expect(forked.summary.workingDirectory == "/tmp")
    #expect(forked.messages.map(\.content) == ["Fake system prompt.", "one", "two"])

    // Parent still exists and lists alongside the fork.
    let listed = try await service.listSessions()
    #expect(listed.map(\.id).contains(id))
    #expect(listed.map(\.id).contains(forked.summary.id))
  }

  @Test func summarizeSplicesRangeIntoNewIdentity() async throws {
    let service = FakeScribeSessionService()
    let session = try await service.createSession(
      ScribeCreateSessionRequest(workingDirectory: "/tmp"))
    let id = session.summary.id
    try await service.appendMessages(
      [
        ScribeMessage(role: .user, content: "one"),
        ScribeMessage(role: .assistant, content: "two"),
        ScribeMessage(role: .user, content: "three"),
        ScribeMessage(role: .assistant, content: "four"),
      ],
      to: id)

    let summarized = try await service.summarize(
      ScribeSummarizeSessionRequest(sessionID: id, startMessageIndex: 1, endMessageIndex: 3))
    #expect(summarized.summary.id != id)
    #expect(summarized.messages.count == 4)
    #expect(summarized.messages[1].role == .assistant)
    #expect(summarized.messages[1].content.contains("TLDR summary"))
    #expect(summarized.messages[2].content == "three")
    #expect(summarized.messages[3].content == "four")
  }

  @Test func unsupportedCapabilitiesRejectForkAndTLDR() async throws {
    let service = FakeScribeSessionService(
      capabilities: ScribeSessionCapabilities(supportsFork: false, supportsTLDR: false))
    let session = try await service.createSession(
      ScribeCreateSessionRequest(workingDirectory: "/tmp"))
    let id = session.summary.id

    do {
      _ = try await service.fork(ScribeForkSessionRequest(sessionID: id, cutAtMessageIndex: 0))
      Issue.record("Expected unsupported")
    } catch let error as ScribeSessionServiceError {
      #expect(error == .unsupported(feature: "fork"))
    }
    do {
      _ = try await service.summarize(
        ScribeSummarizeSessionRequest(sessionID: id, startMessageIndex: 0, endMessageIndex: 1))
      Issue.record("Expected unsupported")
    } catch let error as ScribeSessionServiceError {
      #expect(error == .unsupported(feature: "TLDR"))
    }
  }

  @Test func seededSessionsListPinnedFirstThenRecency() async throws {
    let service = FakeScribeSessionService()
    let pinnedID = UUID()
    let freshID = UUID()
    let staleID = UUID()
    await service.seedSession(
      ScribeSessionSummary(
        id: staleID,
        createdAt: Date(timeIntervalSince1970: 100),
        lastMessageAt: Date(timeIntervalSince1970: 100),
        workingDirectory: "/tmp",
        model: "m"),
      messages: [])
    await service.seedSession(
      ScribeSessionSummary(
        id: pinnedID,
        isPinned: true,
        createdAt: Date(timeIntervalSince1970: 50),
        lastMessageAt: Date(timeIntervalSince1970: 50),
        workingDirectory: "/tmp",
        model: "m"),
      messages: [])
    await service.seedSession(
      ScribeSessionSummary(
        id: freshID,
        createdAt: Date(timeIntervalSince1970: 900),
        lastMessageAt: Date(timeIntervalSince1970: 900),
        workingDirectory: "/tmp",
        model: "m"),
      messages: [])

    let listed = try await service.listSessions()
    #expect(listed.map(\.id) == [pinnedID, freshID, staleID])
  }
}
