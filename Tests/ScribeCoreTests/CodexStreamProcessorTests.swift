import Foundation
import Logging
import OpenAPIRuntime
import Testing

@testable import ScribeCore

// MARK: - Test Helpers

/// Drives a CodexStreamProcessor with the given SSE string and returns the
/// events emitted and the final turn state.
private func driveProcessor(
  sse: String
) async throws -> (events: [AgentEvent], turn: CodexAssistantTurn, processor: CodexStreamProcessor<NoOpAbortObserver>) {
  let body = HTTPBody(sse)
  var events: [AgentEvent] = []
  let logger = Logger(label: "test")
  var processor = CodexStreamProcessor(
    onEvent: { events.append($0) },
    logger: logger,
    abortObserver: NoOpAbortObserver(),
    streamWallStart: .now
  )
  var turn = CodexAssistantTurn()
  try await processor.process(httpBody: body, httpStart: .now, turn: &turn)
  return (events, turn, processor)
}

// MARK: - Terminal Event Finalization Tests

@Test
func codexStreamEmitsFinalizedOnResponseCompletedWithTextDelta() async throws {
  let sse = makeSSE(
    #"{"type":"response.output_text.delta","delta":"Hello"}"#,
    #"{"type":"response.completed","response":{"id":"resp_123","usage":{"input_tokens":10,"output_tokens":5,"total_tokens":15}}}"#
  )

  let (events, turn, processor) = try await driveProcessor(sse: sse)

  #expect(finalizedEvents(in: events).count == 1, "Expected exactly one .finalized event")
  #expect(emptyEvents(in: events).isEmpty)
  #expect(turn.text == "Hello")
  #expect(turn.responseId == "resp_123")
  #expect(processor.lastUsage?.inputTokens == 10)
  #expect(processor.lastUsage?.outputTokens == 5)
}

@Test
func codexStreamEmitsFinalizedOnResponseCompletedWithReasoningDelta() async throws {
  let sse = makeSSE(
    #"{"type":"response.reasoning_text.delta","delta":"Let me think..."}"#,
    #"{"type":"response.completed","response":{"id":"resp_456"}}"#
  )

  let (events, turn, _) = try await driveProcessor(sse: sse)

  #expect(finalizedEvents(in: events).count == 1)
  #expect(emptyEvents(in: events).isEmpty)
  #expect(turn.reasoningText == "Let me think...")
}

@Test
func codexStreamSeparatesAdjacentReasoningSummaryParts() async throws {
  let sse = makeSSE(
    #"{"type":"response.reasoning_summary_text.delta","item_id":"rs_1","output_index":0,"summary_index":0,"delta":"**Planning font catalog redesign**"}"#,
    #"{"type":"response.reasoning_summary_text.delta","item_id":"rs_1","output_index":0,"summary_index":1,"delta":"**Designing custom glyph**"}"#,
    #"{"type":"response.reasoning_summary_text.delta","item_id":"rs_1","output_index":0,"summary_index":1,"delta":" and atlas"}"#,
    #"{"type":"response.completed","response":{"id":"resp_summary"}}"#
  )

  let (events, turn, _) = try await driveProcessor(sse: sse)

  #expect(
    turn.reasoningText
      == "**Planning font catalog redesign**\n\n**Designing custom glyph** and atlas")
  let reasoningText = events.compactMap { event -> String? in
    guard case .output(.text(.reasoning, let text)) = event else { return nil }
    return text
  }.joined()
  #expect(reasoningText == turn.reasoningText)
}

@Test
func codexStreamEmitsFinalizedOnResponseCompletedWithToolCallDeltas() async throws {
  let sse = makeSSE(
    #"{"type":"response.function_call_arguments.delta","delta":"{\"com","output_index":0}"#,
    #"{"type":"response.function_call_arguments.delta","delta":"mand\":\"ls\"}","output_index":0}"#,
    #"{"type":"response.output_item.done","item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"shell","arguments":"{\"command\":\"ls\"}"},"output_index":0}"#,
    #"{"type":"response.completed","response":{"id":"resp_789"}}"#
  )

  let (events, turn, _) = try await driveProcessor(sse: sse)

  #expect(finalizedEvents(in: events).count == 1)
  #expect(emptyEvents(in: events).isEmpty)
  #expect(turn.resolvedToolCalls().count == 1)
  #expect(turn.resolvedToolCalls()[0].name == "shell")
}

@Test
func codexStreamEmitsFinalizedOnResponseIncomplete() async throws {
  let sse = makeSSE(
    #"{"type":"response.output_text.delta","delta":"Partial..."}"#,
    #"{"type":"response.incomplete","response":{"id":"resp_incomplete"}}"#
  )

  let (events, _, _) = try await driveProcessor(sse: sse)

  #expect(finalizedEvents(in: events).count == 1)
  #expect(emptyEvents(in: events).isEmpty)
}

@Test
func codexStreamEmitsEmptyWhenNoContentBeforeResponseCompleted() async throws {
  let sse = makeSSE(
    #"{"type":"response.completed","response":{"id":"resp_empty"}}"#
  )

  let (events, turn, _) = try await driveProcessor(sse: sse)

  #expect(finalizedEvents(in: events).isEmpty)
  #expect(emptyEvents(in: events).count == 1)
  #expect(turn.text.isEmpty)
  #expect(turn.resolvedToolCalls().isEmpty)
}

@Test
func codexStreamWithDoneSentinelStillFinalizes() async throws {
  // When only [DONE] terminates the stream (no response.completed event),
  // the post-loop finalization should still kick in.
  let sse =
    makeSSE(
      #"{"type":"response.output_text.delta","delta":"Hi"}"#
    ) + "data: [DONE]\n\n"

  let (events, turn, _) = try await driveProcessor(sse: sse)

  #expect(finalizedEvents(in: events).count == 1)
  #expect(emptyEvents(in: events).isEmpty)
  #expect(turn.text == "Hi")
}

@Test
func codexStreamSurfacesTopLevelErrorDetails() async throws {
  let sse = makeSSE(
    #"{"type":"error","code":"input_too_large","message":"Request payload exceeds the limit"}"#
  )

  do {
    _ = try await driveProcessor(sse: sse)
    Issue.record("Expected the Codex error event to throw")
  } catch let error as ScribeError {
    #expect(
      error.errorDescription
        == "Request payload exceeds the limit (code: input_too_large)")
  }
}

@Test
func codexStreamSurfacesNestedResponseErrorDetails() async throws {
  let sse = makeSSE(
    #"{"type":"response.failed","response":{"id":"resp_failed","error":{"code":"invalid_image","type":"invalid_request_error","message":"Image could not be processed"}}}"#
  )

  do {
    _ = try await driveProcessor(sse: sse)
    Issue.record("Expected the failed Codex response to throw")
  } catch let error as ScribeError {
    #expect(
      error.errorDescription
        == "Image could not be processed (code: invalid_image, type: invalid_request_error, response: resp_failed)")
  }
}

@Test
func codexStreamIncludesRawEventWhenErrorHasNoMessage() async throws {
  let sse = makeSSE(
    #"{"type":"error","code":"unknown","param":"input"}"#
  )

  do {
    _ = try await driveProcessor(sse: sse)
    Issue.record("Expected the Codex error event to throw")
  } catch let error as ScribeError {
    #expect(
      error.errorDescription
        == #"Codex stream error (code: unknown) — event: {"code":"unknown","param":"input","type":"error"}"#)
  }
}

@Test
func codexStreamEmitsOnlyOneFinalizedWhenBothResponseCompletedAndDonePresent() async throws {
  // If both response.completed and [DONE] appear, the early return
  // from response.completed must prevent a double-finalize from the
  // post-loop path.
  let sse =
    makeSSE(
      #"{"type":"response.output_text.delta","delta":"One and only one"}"#,
      #"{"type":"response.completed","response":{"id":"resp_once"}}"#
    ) + "data: [DONE]\n\n"

  let (events, _, _) = try await driveProcessor(sse: sse)

  #expect(finalizedEvents(in: events).count == 1, "Must not double-emit .finalized")
}
