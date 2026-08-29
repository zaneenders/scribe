import Foundation
import Testing

@testable import ScribeAPI

@Suite
struct ScribeAPIContractTests {
  @Test("decodes an assistant text delta from the per-session stream contract")
  func decodesAssistantTextDelta() throws {
    let data = Data(
      #"{"protocolVersion":1,"eventID":42,"sessionID":"00000000-0000-0000-0000-000000000001","sessionRevision":7,"turnID":"00000000-0000-0000-0000-000000000002","payload":{"type":"assistantTextDelta","entryID":"assistant-1","sectionID":"answer-1","text":"hello"}}"#.utf8
    )

    let envelope = try JSONDecoder().decode(
      Components.Schemas.SessionEventEnvelope.self,
      from: data
    )

    #expect(envelope.protocolVersion == 1)
    #expect(envelope.eventID == 42)
    #expect(envelope.sessionRevision == 7)
    guard case .assistantTextDelta(let delta) = envelope.payload else {
      Issue.record("Expected an assistant text delta")
      return
    }
    #expect(delta.entryID == "assistant-1")
    #expect(delta.sectionID == "answer-1")
    #expect(delta.text == "hello")
  }

  @Test("decodes a cursor-paginated transcript page")
  func decodesTranscriptPage() throws {
    let data = Data(
      #"{"entries":[{"type":"userMessage","id":"message-1","text":"hello"}],"oldestCursor":"opaque-cursor","hasMoreBefore":true,"sessionRevision":9}"#.utf8
    )

    let page = try JSONDecoder().decode(Components.Schemas.TranscriptPage.self, from: data)

    #expect(page.oldestCursor == "opaque-cursor")
    #expect(page.hasMoreBefore)
    #expect(page.sessionRevision == 9)
    #expect(page.entries.count == 1)
    guard case .userMessage(let message) = page.entries[0] else {
      Issue.record("Expected a user message")
      return
    }
    #expect(message.text == "hello")
  }

  @Test("encodes a session creation request")
  func encodesCreateSessionRequest() throws {
    let request = Components.Schemas.CreateSessionRequest(
      workingDirectory: "/tmp/project",
      profileName: "default",
      initialMessage: "Explain this project"
    )

    let data = try JSONEncoder().encode(request)
    let decoded = try JSONDecoder().decode(
      Components.Schemas.CreateSessionRequest.self,
      from: data
    )

    #expect(decoded.workingDirectory == "/tmp/project")
    #expect(decoded.profileName == "default")
    #expect(decoded.initialMessage == "Explain this project")
  }

  @Test("encodes health capabilities using the generated contract")
  func encodesHealthResponse() throws {
    let health = Components.Schemas.HealthResponse(
      status: .ok,
      protocolVersion: 1,
      daemonInstanceID: "00000000-0000-0000-0000-000000000001",
      capabilities: [.sessions, .streaming]
    )

    let data = try JSONEncoder().encode(health)
    let decoded = try JSONDecoder().decode(Components.Schemas.HealthResponse.self, from: data)

    #expect(decoded.status == .ok)
    #expect(decoded.protocolVersion == 1)
    #expect(decoded.capabilities == [.sessions, .streaming])
  }
}
