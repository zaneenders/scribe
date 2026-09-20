import Foundation
import ScribeCore
import Testing

@testable import ScribeKit

@Suite
struct ScribeSessionEventCodingTests {

  private func roundTrip(_ event: ScribeSessionEvent) throws -> ScribeSessionEvent {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let data = try encoder.encode(event)
    return try decoder.decode(ScribeSessionEvent.self, from: data)
  }

  @Test func everyCaseRoundTrips() throws {
    let sessionID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let previousID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let events: [ScribeSessionEvent] = [
      .userPromptAccepted("hello"),
      .sectionStarted(.reasoning),
      .sectionStarted(.answer),
      .sectionTextAppended(.reasoning, text: "thinking"),
      .sectionTextAppended(.answer, text: "hi"),
      .toolRoundStarted(round: 2),
      .toolInvocationStarted(name: "shell", arguments: #"{"command":"ls"}"#),
      .toolInvocationCompleted(name: "shell", output: #"{"ok":true,"exitCode":0}"#),
      .warning("careful"),
      .error("boom"),
      .retrying(attempt: 2, maxAttempts: 3, delaySeconds: 1.5, reason: "rate limited"),
      .recovered(reason: "compacted context"),
      .usage(ScribeUsageSnapshot(totalTokens: 42, tokensPerSecond: 10.5)),
      .emptyOutput,
      .interrupted,
      .identityChanged(previousSessionID: previousID, sessionID: sessionID),
      .turnCompleted(.completed, messages: []),
      .turnCompleted(.incomplete(reason: "budget"), messages: [
        ScribeMessage(role: .user, content: "hi"),
        ScribeMessage(role: .assistant, content: "partial"),
      ]),
      .turnCompleted(.interrupted, messages: []),
      .turnCompleted(.toolRoundLimit(rounds: 12), messages: []),
      .turnCompleted(.error("provider down"), messages: []),
      .turnFailed("Connection lost."),
    ]
    for event in events {
      #expect(try roundTrip(event) == event)
    }
  }

  private struct TagBox: Decodable {
    let type: String
  }

  @Test func encodedTagsAreStableStrings() throws {
    func tag(_ event: ScribeSessionEvent) throws -> String {
      let json = try JSONEncoder().encode(event)
      return try JSONDecoder().decode(TagBox.self, from: json).type
    }
    #expect(try tag(.userPromptAccepted("x")) == "user_prompt_accepted")
    #expect(try tag(.sectionStarted(.answer)) == "section_started")
    #expect(try tag(.sectionTextAppended(.answer, text: "x")) == "section_text_appended")
    #expect(try tag(.toolRoundStarted(round: 1)) == "tool_round_started")
    #expect(try tag(.toolInvocationStarted(name: "n", arguments: "a")) == "tool_invocation_started")
    #expect(try tag(.toolInvocationCompleted(name: "n", output: "o")) == "tool_invocation_completed")
    #expect(try tag(.warning("x")) == "warning")
    #expect(try tag(.error("x")) == "error")
    #expect(
      try tag(.retrying(attempt: 1, maxAttempts: 2, delaySeconds: 1, reason: "r")) == "retrying")
    #expect(try tag(.recovered(reason: "r")) == "recovered")
    #expect(try tag(.usage(ScribeUsageSnapshot())) == "usage")
    #expect(try tag(.emptyOutput) == "empty_output")
    #expect(try tag(.interrupted) == "interrupted")
    #expect(
      try tag(.identityChanged(previousSessionID: UUID(), sessionID: UUID()))
        == "identity_changed")
    #expect(try tag(.turnCompleted(.completed, messages: [])) == "turn_completed")
    #expect(try tag(.turnFailed("x")) == "turn_failed")
  }

  @Test func unknownTagFailsExplicitlyInsteadOfCompleting() throws {
    let json = #"{"type":"quantum_state_collapse"}"#
    let data = Data(json.utf8)
    do {
      _ = try JSONDecoder().decode(ScribeSessionEvent.self, from: data)
      Issue.record("Expected decoding to throw for an unknown tag")
    } catch let error as ScribeSessionEventCodingError {
      guard case .unknownTag(let tag) = error else {
        Issue.record("Expected unknownTag, got \(error)")
        return
      }
      #expect(tag == "quantum_state_collapse")
    }
  }

  @Test func unknownTurnOutcomeKindFailsExplicitly() throws {
    let json = #"{"type":"turn_completed","outcome":{"kind":"wormhole"},"messages":[]}"#
    do {
      _ = try JSONDecoder().decode(ScribeSessionEvent.self, from: Data(json.utf8))
      Issue.record("Expected decoding to throw for an unknown outcome kind")
    } catch let error as ScribeSessionEventCodingError {
      guard case .unknownTag(let kind) = error else {
        Issue.record("Expected unknownTag, got \(error)")
        return
      }
      #expect(kind == "wormhole")
    }
  }

  @Test func terminalFlagIdentifiesTerminalEventsOnly() {
    #expect(ScribeSessionEvent.turnCompleted(.completed, messages: []).isTerminal)
    #expect(ScribeSessionEvent.turnFailed("x").isTerminal)
    #expect(!ScribeSessionEvent.interrupted.isTerminal)
    #expect(!ScribeSessionEvent.userPromptAccepted("x").isTerminal)
    #expect(!ScribeSessionEvent.sectionTextAppended(.answer, text: "x").isTerminal)
  }
}
