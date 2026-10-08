import Foundation
import Logging
import OpenAPIRuntime
import Testing

@testable import ScribeCore

private func driveProcessor(
  sse: String
) async throws -> (
  events: [AgentEvent], turn: ResponsesAssistantTurn, processor: ResponsesStreamProcessor<NoOpAbortObserver>
) {
  let body = HTTPBody(sse)
  var events: [AgentEvent] = []
  let logger = Logger(label: "test")
  var processor = ResponsesStreamProcessor(
    onEvent: { events.append($0) },
    logger: logger,
    abortObserver: NoOpAbortObserver(),
    streamWallStart: .now
  )
  var turn = ResponsesAssistantTurn()
  try await processor.process(httpBody: body, httpStart: .now, turn: &turn)
  return (events, turn, processor)
}

@Test
func responsesStreamEmitsFinalizedOnResponseCompletedWithTextDelta() async throws {
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
func responsesStreamEmitsFinalizedOnResponseCompletedWithReasoningDelta() async throws {
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
func responsesStreamSeparatesAdjacentReasoningSummaryParts() async throws {
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
func responsesStreamEmitsFinalizedOnResponseCompletedWithToolCallDeltas() async throws {
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
func responsesStreamEmitsFinalizedOnResponseIncomplete() async throws {
  let sse = makeSSE(
    #"{"type":"response.output_text.delta","delta":"Partial..."}"#,
    #"{"type":"response.incomplete","response":{"id":"resp_incomplete"}}"#
  )

  let (events, _, _) = try await driveProcessor(sse: sse)

  #expect(finalizedEvents(in: events).count == 1)
  #expect(emptyEvents(in: events).isEmpty)
}

@Test
func responsesStreamEmitsEmptyWhenNoContentBeforeResponseCompleted() async throws {
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
func responsesStreamWithDoneSentinelStillFinalizes() async throws {
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
func responsesStreamSurfacesTopLevelErrorDetails() async throws {
  let sse = makeSSE(
    #"{"type":"error","code":"input_too_large","message":"Request payload exceeds the limit"}"#
  )

  do {
    _ = try await driveProcessor(sse: sse)
    Issue.record("Expected the Responses error event to throw")
  } catch let error as ScribeError {
    #expect(
      error.errorDescription
        == "Request payload exceeds the limit (code: input_too_large)")
  }
}

@Test
func responsesStreamSurfacesNestedResponseErrorDetails() async throws {
  let sse = makeSSE(
    #"{"type":"response.failed","response":{"id":"resp_failed","error":{"code":"invalid_image","type":"invalid_request_error","message":"Image could not be processed"}}}"#
  )

  do {
    _ = try await driveProcessor(sse: sse)
    Issue.record("Expected the failed Responses response to throw")
  } catch let error as ScribeError {
    #expect(
      error.errorDescription
        == "Image could not be processed (code: invalid_image, type: invalid_request_error, response: resp_failed)")
  }
}

@Test
func responsesStreamIncludesRawEventWhenErrorHasNoMessage() async throws {
  let sse = makeSSE(
    #"{"type":"error","code":"unknown","param":"input"}"#
  )

  do {
    _ = try await driveProcessor(sse: sse)
    Issue.record("Expected the Responses error event to throw")
  } catch let error as ScribeError {
    #expect(
      error.errorDescription
        == #"Responses stream error (code: unknown) — event: {"code":"unknown","param":"input","type":"error"}"#)
  }
}

@Test
func responsesStreamEmitsOnlyOneFinalizedWhenBothResponseCompletedAndDonePresent() async throws {
  let sse =
    makeSSE(
      #"{"type":"response.output_text.delta","delta":"One and only one"}"#,
      #"{"type":"response.completed","response":{"id":"resp_once"}}"#
    ) + "data: [DONE]\n\n"

  let (events, _, _) = try await driveProcessor(sse: sse)

  #expect(finalizedEvents(in: events).count == 1, "Must not double-emit .finalized")
}

@Test func codexStreamErrorsNeverExposeProviderBodies() async throws {
  var processor = ResponsesStreamProcessor(
    onEvent: { _ in }, logger: Logger(label: "test.redaction"),
    abortObserver: NoOpAbortObserver(), streamWallStart: .now, redactErrors: true)
  var turn = ResponsesAssistantTurn()
  do {
    try await processor.process(
      httpBody: HTTPBody(
        makeSSE(
          #"{"type":"error","message":"access-secret","error":{"message":"refresh-secret"}}"#)),
      httpStart: .now, turn: &turn)
    Issue.record("Expected a safe failure")
  } catch {
    #expect(!String(describing: error).contains("secret"))
    #expect(!error.localizedDescription.contains("secret"))
  }
}

@Test func codexTransportFailureLogsSafeDiagnosticsAndFinalizesPartialOutput() async throws {
  let logs = LogRecorder()
  var events: [AgentEvent] = []
  var processor = ResponsesStreamProcessor(
    onEvent: { events.append($0) }, logger: logs.logger(),
    abortObserver: NoOpAbortObserver(), streamWallStart: .now, redactErrors: true)
  let body = HTTPBody(
    AsyncThrowingStream<HTTPBody.ByteChunk, any Error> { continuation in
      continuation.yield(
        Array(
          makeSSE(
            #"{"type":"response.created","response":{"id":"secret-response-id"}}"#,
            #"{"type":"response.reasoning_summary_text.delta","delta":"secret-content","sequence_number":7}"#
          ).utf8)[...])
      continuation.finish(
        throwing: URLError(.networkConnectionLost, userInfo: [NSLocalizedDescriptionKey: "secret-token"]))
    }, length: .unknown)
  var turn = ResponsesAssistantTurn()
  do {
    try await processor.process(httpBody: body, httpStart: .now, turn: &turn)
    Issue.record("Expected stream failure")
  } catch {
    #expect(error.localizedDescription == "Codex response stream unavailable.")
    #expect(!String(describing: error).contains("secret"))
  }
  let entries = logs.entries.withLock { $0 }
  let failure = try #require(entries.first { $0.message == "agent.stream.error.responses" })
  #expect(failure.metadata["underlying_error_type"]?.description.contains("URLError") == true)
  #expect(failure.metadata["error_code"] == "-1005")
  #expect(failure.metadata["retryable"] == "true")
  #expect(failure.metadata["decoded_chunks"] == "2")
  #expect(failure.metadata["last_event_type"] == "response.reasoning_summary_text.delta")
  #expect(failure.metadata["last_sequence_number"] == "7")
  #expect(failure.metadata["stream_started"] == "true")
  #expect(failure.metadata["terminal_event_received"] == "false")
  #expect(failure.metadata["stream_elapsed_ms"] != nil)
  #expect(failure.metadata["last_chunk_age_ms"] != nil)
  #expect(!String(describing: entries).contains("secret"))
  #expect(finalizedEvents(in: events).count == 1)
  #expect(turn.reasoningText == "secret-content")
}

@Test func codexProviderFailureLogsOnlyAllowlistedCodes() async throws {
  let logs = LogRecorder()
  var processor = ResponsesStreamProcessor(
    onEvent: { _ in }, logger: logs.logger(),
    abortObserver: NoOpAbortObserver(), streamWallStart: .now, redactErrors: true)
  var turn = ResponsesAssistantTurn()
  await #expect(throws: ScribeError.self) {
    try await processor.process(
      httpBody: HTTPBody(
        makeSSE(
          #"{"type":"response.failed","sequence_number":9,"response":{"id":"secret-id","error":{"code":"server_error","type":"secret-type","message":"secret-message"}}}"#
        )), httpStart: .now, turn: &turn)
  }
  let entries = logs.entries.withLock { $0 }
  let failure = try #require(entries.first { $0.message == "agent.stream.provider-error.responses" })
  #expect(failure.metadata["code"] == "server_error")
  #expect(failure.metadata["provider_error_type"] == "redacted")
  #expect(failure.metadata["terminal_event_received"] == "true")
  #expect(failure.metadata["last_event_type"] == "response.failed")
  #expect(failure.metadata["last_sequence_number"] == "9")
  #expect(!String(describing: entries).contains("secret"))
}

@Test func codexPrematureEndLogsStreamStateWithoutUnknownEventContent() async throws {
  let logs = LogRecorder()
  var processor = ResponsesStreamProcessor(
    onEvent: { _ in }, logger: logs.logger(),
    abortObserver: NoOpAbortObserver(), streamWallStart: .now, redactErrors: true)
  var turn = ResponsesAssistantTurn()
  try await processor.process(
    httpBody: HTTPBody(makeSSE("secret-malformed-json", #"{"type":"secret-event"}"#)),
    httpStart: .now, turn: &turn)
  let entries = logs.entries.withLock { $0 }
  let failure = try #require(entries.first { $0.message == "agent.stream.incomplete.responses" })
  #expect(processor.isIncomplete)
  #expect(failure.metadata["last_event_type"] == "other")
  #expect(failure.metadata["decoded_chunks"] == "1")
  #expect(failure.metadata["unreadable_chunks"] == "1")
  #expect(!String(describing: entries).contains("secret"))
}
