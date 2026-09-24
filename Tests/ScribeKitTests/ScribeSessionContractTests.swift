import Foundation
import ScribeCore
import Testing

@testable import ScribeKit

@Suite
struct ScribeSessionContractTests {

  @Test func summaryAndSnapshotRoundTrip() throws {
    let summary = ScribeSessionSummary(
      id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
      name: "Refactor",
      isPinned: true,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      lastMessageAt: Date(timeIntervalSince1970: 1_700_000_500),
      workingDirectory: "/tmp/project",
      profileName: "codex",
      model: "gpt-5.6-sol")
    let snapshot = ScribeSessionSnapshot(
      summary: summary,
      messages: [
        ScribeMessage(role: .system, content: "sys"),
        ScribeMessage(role: .user, content: "hello"),
        ScribeMessage(role: .assistant, content: "hi", reasoning: "thinking"),
      ],
      profileCatalog: [
        ScribeProfileSummary(name: "codex", model: "gpt-5.6-sol", baseURL: "https://chatgpt.com/backend-api"),
        ScribeProfileSummary(name: "local", model: "gemma4:e2b", baseURL: "http://localhost:11434"),
      ],
      serviceTier: "priority")

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let data = try encoder.encode(snapshot)
    let decoded = try decoder.decode(ScribeSessionSnapshot.self, from: data)

    #expect(decoded == snapshot)
    #expect(decoded.summary.displayName == "Refactor")
    #expect(decoded.messages.first?.role == .system)
  }

  @Test func unnamedSummaryFallsBackToShortID() {
    let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let summary = ScribeSessionSummary(
      id: id,
      createdAt: Date(),
      lastMessageAt: Date(),
      workingDirectory: "/tmp",
      model: "m")
    #expect(summary.name == nil)
    #expect(summary.displayName == "11111111")
  }

  @Test func capabilitiesRoundTrip() throws {
    let capabilities = ScribeSessionCapabilities(
      supportsProfileSwitching: true,
      supportsFork: false,
      supportsTLDR: true,
      supportsDirectorySelection: false)
    let data = try JSONEncoder().encode(capabilities)
    #expect(try JSONDecoder().decode(ScribeSessionCapabilities.self, from: data) == capabilities)
  }

  @Test func profileSummaryRoundTrip() throws {
    let profile = ScribeProfileSummary(
      name: "local", model: "gemma4:e2b", baseURL: "http://localhost:11434",
      reasoningEfforts: ["low", "medium", "high"], reasoningEffort: "medium",
      serviceTiers: ["default", "priority"], serviceTier: "priority")
    let data = try JSONEncoder().encode(profile)
    #expect(try JSONDecoder().decode(ScribeProfileSummary.self, from: data) == profile)
  }

  @Test func nameUpdateDistinguishesUnchangedSetAndCleared() throws {
    let updates: [ScribeNameUpdate] = [.unchanged, .set("Refactor"), .cleared]
    for update in updates {
      let data = try JSONEncoder().encode(update)
      #expect(try JSONDecoder().decode(ScribeNameUpdate.self, from: data) == update)
    }
    #expect(ScribeNameUpdate.unchanged != ScribeNameUpdate.cleared)
    #expect(ScribeNameUpdate.set("A") != ScribeNameUpdate.set("B"))
  }

  @Test func serviceErrorMessagesAreDisplaySafe() {
    let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let errors: [ScribeSessionServiceError] = [
      .notFound(sessionID: id),
      .busy(sessionID: id),
      .unsupported(feature: "fork"),
      .invalidRequest("Prompt must not be empty."),
      .failed("Could not reach the provider."),
    ]
    for error in errors {
      let message = error.errorDescription
      #expect(message != nil)
      #expect(!message!.isEmpty)
    }
    #expect(
      ScribeSessionServiceError.notFound(sessionID: id).errorDescription
        == "Session 11111111 could not be found.")
    #expect(
      ScribeSessionServiceError.busy(sessionID: id).errorDescription
        == "Session 11111111 is already running a turn.")
  }

  @Test func requestsCarryStructuredValues() {
    let id = UUID()
    #expect(
      ScribeCreateSessionRequest(workingDirectory: "/tmp", profileName: "codex")
        == ScribeCreateSessionRequest(workingDirectory: "/tmp", profileName: "codex"))
    #expect(
      ScribeSubmitRequest(sessionID: id, prompt: "hello")
        == ScribeSubmitRequest(sessionID: id, prompt: "hello"))
    #expect(
      ScribePresentationUpdate(sessionID: id, name: .cleared, isPinned: true)
        == ScribePresentationUpdate(sessionID: id, name: .cleared, isPinned: true))
    #expect(
      ScribeReconfigureSessionRequest(sessionID: id, profileName: "codex")
        == ScribeReconfigureSessionRequest(sessionID: id, profileName: "codex"))
    #expect(
      ScribeForkSessionRequest(sessionID: id, cutAtMessageIndex: 4)
        == ScribeForkSessionRequest(sessionID: id, cutAtMessageIndex: 4))
    #expect(
      ScribeSummarizeSessionRequest(sessionID: id, startMessageIndex: 2, endMessageIndex: 6, model: "m")
        == ScribeSummarizeSessionRequest(sessionID: id, startMessageIndex: 2, endMessageIndex: 6, model: "m"))
  }
}
