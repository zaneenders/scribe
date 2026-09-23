import Foundation
import HTTPTypes
import OpenAPIRuntime
import ScribeCore
import ScribeLLM
import Synchronization
import SystemPackage
import Testing

@testable import ScribeKit

@Suite
struct LocalScribeSessionServiceTests {

  @Test func unknownSessionsAreNotFound() async throws {
    try await withLocalServiceFixture { fixture in
      let service = try await fixture.makeService()
      let missing = UUID()

      do {
        _ = try await service.openSession(id: missing)
        Issue.record("Expected notFound")
      } catch let error as ScribeSessionServiceError {
        #expect(error == .notFound(sessionID: missing))
      }
      do {
        _ = try await service.submit(ScribeSubmitRequest(sessionID: missing, prompt: "hi"))
        Issue.record("Expected notFound")
      } catch let error as ScribeSessionServiceError {
        #expect(error == .notFound(sessionID: missing))
      }
      do {
        try await service.interrupt(sessionID: missing)
        Issue.record("Expected notFound")
      } catch let error as ScribeSessionServiceError {
        #expect(error == .notFound(sessionID: missing))
      }
      do {
        _ = try await service.fork(ScribeForkSessionRequest(sessionID: missing, cutAtMessageIndex: 0))
        Issue.record("Expected notFound")
      } catch let error as ScribeSessionServiceError {
        #expect(error == .notFound(sessionID: missing))
      }
    }
  }

  @Test func blankPromptsAreInvalidRequests() async throws {
    try await withLocalServiceFixture { fixture in
      let service = try await fixture.makeService()
      let session = try await service.createSession(
        ScribeCreateSessionRequest(workingDirectory: "/tmp"))
      do {
        _ = try await service.submit(
          ScribeSubmitRequest(sessionID: session.summary.id, prompt: "  \n "))
        Issue.record("Expected invalidRequest")
      } catch let error as ScribeSessionServiceError {
        guard case .invalidRequest = error else {
          Issue.record("Expected invalidRequest, got \(error)")
          return
        }
      }
    }
  }

  @Test func concurrentFirstSubmissionsReserveTheSessionBeforeLoading() async throws {
    try await withLocalServiceFixture { fixture in
      let creator = try await fixture.makeService()
      let created = try await creator.createSession(
        ScribeCreateSessionRequest(workingDirectory: "/tmp"))
      let service = try await fixture.makeService()
      let sessionID = created.summary.id
      let first = Task {
        try await service.submit(ScribeSubmitRequest(sessionID: sessionID, prompt: "first"))
      }
      let second = Task {
        try await service.submit(ScribeSubmitRequest(sessionID: sessionID, prompt: "second"))
      }
      let results = await [first.result, second.result]
      let streams = results.compactMap { try? $0.get() }
      #expect(streams.count == 1)
      #expect(
        results.contains { result in
          if case .failure(ScribeSessionServiceError.busy(sessionID: sessionID)) = result {
            return true
          }
          return false
        })
      if let stream = streams.first {
        _ = try await ScribeServiceContractScenarios.collectEvents(from: stream)
      }
    }
  }

  @Test func presentationUpdatesAfterForkApplyToTheFork() async throws {
    try await withLocalServiceFixture { fixture in
      let service = try await fixture.makeService()
      let session = try await service.createSession(
        ScribeCreateSessionRequest(workingDirectory: "/tmp"))
      _ = try await ScribeServiceContractScenarios.collectEvents(
        from: try await service.submit(
          ScribeSubmitRequest(sessionID: session.summary.id, prompt: "hello")))
      let opened = try await service.openSession(id: session.summary.id)
      let forked = try await service.fork(
        ScribeForkSessionRequest(
          sessionID: session.summary.id,
          cutAtMessageIndex: opened.messages.count))

      let updated = try await service.updatePresentation(
        ScribePresentationUpdate(sessionID: forked.summary.id, name: .set("Forked"), isPinned: true))

      #expect(updated.name == "Forked")
      #expect(updated.isPinned)
      let sessions = try await service.listSessions()
      #expect(sessions.first(where: { $0.id == session.summary.id })?.name == nil)
      #expect(sessions.first(where: { $0.id == session.summary.id })?.isPinned == false)
      #expect(sessions.first(where: { $0.id == forked.summary.id })?.name == "Forked")
      #expect(sessions.first(where: { $0.id == forked.summary.id })?.isPinned == true)
    }
  }

  @Test func concurrentInterruptsBothWaitForTurnCompletion() async throws {
    try await withLocalServiceFixture { fixture in
      let service = try await fixture.makeService()
      let session = try await service.createSession(
        ScribeCreateSessionRequest(workingDirectory: "/tmp"))
      let sessionID = session.summary.id
      let stream = try await fixture.startBlockedTurn(service, sessionID: sessionID, prompt: "held")

      async let firstInterrupt: Void = service.interrupt(sessionID: sessionID)
      async let secondInterrupt: Void = service.interrupt(sessionID: sessionID)
      try await firstInterrupt
      try await secondInterrupt

      let events = try await ScribeServiceContractScenarios.collectEvents(from: stream)
      #expect(events.filter(\.isTerminal).count == 1)
      let next = try await ScribeServiceContractScenarios.collectEvents(
        from: try await service.submit(
          ScribeSubmitRequest(sessionID: sessionID, prompt: "next")))
      #expect(next.filter(\.isTerminal).count == 1)
    }
  }

  @Test func forkAtUnsafeBoundaryIsRejected() async throws {
    try await withLocalServiceFixture { fixture in
      let service = try await fixture.makeService()
      let session = try await service.createSession(
        ScribeCreateSessionRequest(workingDirectory: "/tmp"))
      let sessionID = session.summary.id
      _ = try await ScribeServiceContractScenarios.collectEvents(
        from: try await service.submit(ScribeSubmitRequest(sessionID: sessionID, prompt: "hi")))
      do {
        _ = try await service.fork(ScribeForkSessionRequest(sessionID: sessionID, cutAtMessageIndex: 99))
        Issue.record("Expected invalidRequest")
      } catch let error as ScribeSessionServiceError {
        guard case .invalidRequest = error else {
          Issue.record("Expected invalidRequest, got \(error)")
          return
        }
      }
    }
  }

  @Test func forkAndReconfigureDuringActiveSubmissionAreBusy() async throws {
    try await withLocalServiceFixture { fixture in
      let service = try await fixture.makeService()
      let session = try await service.createSession(
        ScribeCreateSessionRequest(workingDirectory: "/tmp"))
      let sessionID = session.summary.id

      _ = try await fixture.startBlockedTurn(service, sessionID: sessionID, prompt: "held")
      do {
        _ = try await service.fork(ScribeForkSessionRequest(sessionID: sessionID, cutAtMessageIndex: 1))
        Issue.record("Expected busy")
      } catch let error as ScribeSessionServiceError {
        #expect(error == .busy(sessionID: sessionID))
      }
      do {
        _ = try await service.reconfigure(
          ScribeReconfigureSessionRequest(sessionID: sessionID, profileName: "beta"))
        Issue.record("Expected busy")
      } catch let error as ScribeSessionServiceError {
        #expect(error == .busy(sessionID: sessionID))
      }
      try await fixture.finishBlockedTurn(service, sessionID: sessionID)
      let forked = try await service.fork(
        ScribeForkSessionRequest(sessionID: sessionID, cutAtMessageIndex: 2))
      #expect(forked.summary.id != sessionID)
    }
  }

  @Test func newServiceInstanceReopensAndContinuesSessions() async throws {
    try await withLocalServiceFixture(
      replies: ["first answer", "second answer", "third answer"]
    ) { fixture in
      let oldService = try await fixture.makeService()
      let created = try await oldService.createSession(
        ScribeCreateSessionRequest(workingDirectory: "/tmp/project"))
      let sessionID = created.summary.id
      let events = try await ScribeServiceContractScenarios.collectEvents(
        from: try await oldService.submit(
          ScribeSubmitRequest(sessionID: sessionID, prompt: "hello")))
      #expect(events.filter(\.isTerminal).count == 1)

      let newService = try await fixture.makeService()
      let listed = try await newService.listSessions()
      #expect(listed.map(\.id).contains(sessionID))
      #expect(listed.first(where: { $0.id == sessionID })?.workingDirectory == "/tmp/project")

      let reopened = try await newService.openSession(id: sessionID)
      #expect(reopened.summary.id == sessionID)
      #expect(reopened.messages.contains { $0.role == .user && $0.content == "hello" })
      #expect(reopened.messages.contains { $0.role == .assistant && $0.content == "first answer" })

      let continued = try await ScribeServiceContractScenarios.collectEvents(
        from: try await newService.submit(
          ScribeSubmitRequest(sessionID: sessionID, prompt: "continue")))
      #expect(continued.filter(\.isTerminal).count == 1)
      let after = try await newService.openSession(id: sessionID)
      #expect(
        after.messages.contains { $0.role == .assistant && $0.content == "second answer" })
    }
  }

  @Test func reopenedSessionKeepsItsWorkingDirectory() async throws {
    try await withLocalServiceFixture(replies: ["first answer", "second answer"]) { fixture in
      let oldService = try await fixture.makeService()
      let created = try await oldService.createSession(
        ScribeCreateSessionRequest(workingDirectory: "/tmp/project"))
      let sessionID = created.summary.id
      _ = try await ScribeServiceContractScenarios.collectEvents(
        from: try await oldService.submit(
          ScribeSubmitRequest(sessionID: sessionID, prompt: "hello")))

      let observed = Mutex<String?>(nil)
      let transport = fixture.transport
      let client = Client(serverURL: URL(string: "http://test")!, transport: transport)
      let newService = LocalScribeSessionService(
        context: fixture.context,
        agentFactory: { configuration, logger in
          observed.withLock { $0 = configuration.workingDirectory }
          return ScribeAgent(
            client: client,
            model: configuration.agentModel,
            workingDirectory: FilePath(configuration.workingDirectory),
            reasoningEnabled: nil,
            logger: logger)
        })

      _ = try await newService.openSession(id: sessionID)
      #expect(observed.withLock { $0 } == "/tmp/project")
    }
  }

  @Test func firstTurnOfNewSessionRunsInRequestedDirectory() async throws {
    try await withLocalServiceFixture(replies: ["answer"]) { fixture in
      let observed = Mutex<String?>(nil)
      let transport = fixture.transport
      let client = Client(serverURL: URL(string: "http://test")!, transport: transport)
      let service = LocalScribeSessionService(
        context: fixture.context,
        agentFactory: { configuration, logger in
          observed.withLock { $0 = configuration.workingDirectory }
          return ScribeAgent(
            client: client,
            model: configuration.agentModel,
            workingDirectory: FilePath(configuration.workingDirectory),
            reasoningEnabled: nil,
            logger: logger)
        })

      let created = try await service.createSession(
        ScribeCreateSessionRequest(workingDirectory: "/tmp/project"))
      _ = try await ScribeServiceContractScenarios.collectEvents(
        from: try await service.submit(
          ScribeSubmitRequest(sessionID: created.summary.id, prompt: "hello")))
      #expect(observed.withLock { $0 } == "/tmp/project")
    }
  }

  @Test func discardingRuntimeKeepsPersistedSessions() async throws {
    try await withLocalServiceFixture { fixture in
      let service = try await fixture.makeService()
      let created = try await service.createSession(
        ScribeCreateSessionRequest(workingDirectory: "/tmp"))
      let sessionID = created.summary.id
      _ = try await ScribeServiceContractScenarios.collectEvents(
        from: try await service.submit(ScribeSubmitRequest(sessionID: sessionID, prompt: "hi")))

      await service.discardRuntime(sessionID: sessionID)
      let reopened = try await service.openSession(id: sessionID)
      #expect(reopened.summary.id == sessionID)
      #expect(reopened.messages.contains { $0.role == .user && $0.content == "hi" })

      let listed = try await service.listSessions()
      #expect(listed.map(\.id).contains(sessionID))
    }
  }

  @Test func submitMapsStreamedSectionsThroughTheAgentEventMapper() async throws {
    try await withLocalServiceFixture(replies: ["streamed answer"]) { fixture in
      let service = try await fixture.makeService()
      let created = try await service.createSession(
        ScribeCreateSessionRequest(workingDirectory: "/tmp"))
      let events = try await ScribeServiceContractScenarios.collectEvents(
        from: try await service.submit(
          ScribeSubmitRequest(sessionID: created.summary.id, prompt: "hello")))

      #expect(events.contains { $0 == .sectionStarted(.answer) })
      #expect(
        events.contains {
          $0 == .sectionTextAppended(.answer, text: "streamed answer")
        })

      let sectionIndexes = events.indices.filter {
        events[$0] == .sectionStarted(.answer)
      }
      let terminalIndexes = events.indices.filter { events[$0].isTerminal }
      #expect(!sectionIndexes.isEmpty && !terminalIndexes.isEmpty)
      #expect(sectionIndexes[0] < terminalIndexes[0])
    }
  }

  @Test func emptySecondTurnDoesNotReuseEarlierAssistantAnswer() async throws {
    try await withLocalServiceFixture(replies: ["first answer", ""]) { fixture in
      let service = try await fixture.makeService()
      let created = try await service.createSession(
        ScribeCreateSessionRequest(workingDirectory: "/tmp"))
      let id = created.summary.id
      _ = try await ScribeServiceContractScenarios.collectEvents(
        from: try await service.submit(.init(sessionID: id, prompt: "first")))
      let events = try await ScribeServiceContractScenarios.collectEvents(
        from: try await service.submit(.init(sessionID: id, prompt: "second")))
      #expect(
        events.contains { event in
          if case .turnCompleted(.completed, _) = event { return false }
          if case .turnFailed = event { return true }
          return false
        })
    }
  }

  @Test func unexpectedDisconnectSurfacesAsTerminalFailure() async throws {
    try await withTemporaryDirectory { root in
      let fixture = try LocalServiceFixture(root: FilePath(root.path))
      let transport = BadPayloadTransport()
      let client = Client(serverURL: URL(string: "http://test")!, transport: transport)
      let service = LocalScribeSessionService(
        context: fixture.context,
        agentFactory: { configuration, logger in
          ScribeAgent(
            client: client,
            model: configuration.agentModel,
            workingDirectory: FilePath(configuration.workingDirectory),
            reasoningEnabled: nil,
            logger: logger)
        })
      let created = try await service.createSession(
        ScribeCreateSessionRequest(workingDirectory: "/tmp"))

      var sawTerminalFailure = false
      do {
        for try await event in try await service.submit(
          ScribeSubmitRequest(sessionID: created.summary.id, prompt: "hello"))
        {
          if case .turnFailed = event {
            sawTerminalFailure = true
          }
          if event.isTerminal, !sawTerminalFailure {
            Issue.record("Unexpected terminal success \(event)")
          }
        }
      } catch {
      }
      #expect(sawTerminalFailure)
    }
  }
}

private struct BadPayloadTransport: ClientTransport, Sendable {
  func send(
    _ request: HTTPRequest,
    body: HTTPBody?,
    baseURL: URL,
    operationID: String
  ) async throws -> (HTTPResponse, HTTPBody?) {
    if let body {
      for try await _ in body {}
    }
    let payload = "data: {not json at all}\n\n"
    let httpBody = HTTPBody(
      AsyncStream { continuation in
        continuation.yield(ArraySlice(payload.utf8))
        continuation.finish()
      },
      length: .unknown)
    return (HTTPResponse(status: .init(code: 200)), httpBody)
  }
}
