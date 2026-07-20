import Foundation
import Logging
import OpenAPIRuntime
import Testing

@testable import ScribeCore

// MARK: - Test Helpers

private struct NoOpAbortObserver: AbortObserver {
    func isAborted() -> Bool { false }
    func signals() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
}

/// Builds an SSE string from data payloads.
private func makeSSE(_ events: String...) -> String {
    events.map { "data: \($0)\n\n" }.joined()
}

/// Drives a StreamProcessor with the given SSE string and returns the events and turn state.
private func driveProcessor(
    sse: String
) async throws -> (events: [AgentEvent], turn: StreamedAssistantTurn, processor: StreamProcessor<NoOpAbortObserver>) {
    let body = HTTPBody(sse)
    var events: [AgentEvent] = []
    let logger = Logger(label: "test.stream-processor")
    var processor = StreamProcessor<NoOpAbortObserver>(
        onEvent: { events.append($0) },
        logger: logger,
        abortObserver: NoOpAbortObserver(),
        streamWallStart: .now
    )
    var turn = StreamedAssistantTurn()
    try await processor.process(httpBody: body, httpStart: .now, turn: &turn)
    return (events, turn, processor)
}

private func finalizedEvents(in events: [AgentEvent]) -> [AgentEvent] {
    events.filter {
        if case .output(.finalized) = $0 { return true }
        return false
    }
}

private func emptyEvents(in events: [AgentEvent]) -> [AgentEvent] {
    events.filter {
        if case .output(.empty) = $0 { return true }
        return false
    }
}

// MARK: - Terminal Event Finalization

@Suite
struct OpenAICompletionsStreamProcessorTests {

    @Test("emits finalized on content delta")
    func emitsFinalizedOnContentDelta() async throws {
        let sse = makeSSE(
            #"{"id":"chatcmpl-123","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}]}"#,
            #"{"id":"chatcmpl-123","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}"#
        )

        let (events, turn, processor) = try await driveProcessor(sse: sse)

        #expect(finalizedEvents(in: events).count == 1)
        #expect(emptyEvents(in: events).isEmpty)
        #expect(turn.text == "Hello")
        #expect(processor.lastUsage?.totalTokens == 15)
    }

    @Test("emits finalized on reasoning content delta")
    func emitsFinalizedOnReasoningDelta() async throws {
        let sse = makeSSE(
            #"{"id":"chatcmpl-456","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"reasoning_content":"Let me think..."},"finish_reason":null}]}"#,
            #"{"id":"chatcmpl-456","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#
        )

        let (events, turn, _) = try await driveProcessor(sse: sse)

        #expect(finalizedEvents(in: events).count == 1)
        #expect(emptyEvents(in: events).isEmpty)
        #expect(turn.reasoningText == "Let me think...")
    }

    @Test("emits finalized on tool call deltas")
    func emitsFinalizedOnToolCallDeltas() async throws {
        let sse = makeSSE(
            #"{"id":"chatcmpl-789","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"shell","arguments":""}}]},"finish_reason":null}]}"#,
            #"{"id":"chatcmpl-789","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"command\":\"ls\"}"}}]},"finish_reason":null}]}"#,
            #"{"id":"chatcmpl-789","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":" "},"finish_reason":"tool_calls"}]}"#
        )

        let (events, turn, _) = try await driveProcessor(sse: sse)

        #expect(finalizedEvents(in: events).count == 1)
        #expect(emptyEvents(in: events).isEmpty)
        #expect(turn.resolvedToolCalls().count == 1)
        #expect(turn.resolvedToolCalls()[0].name == "shell")
    }

    @Test("emits empty when no content before finish")
    func emitsEmptyWhenNoContent() async throws {
        let sse = makeSSE(
            #"{"id":"chatcmpl-empty","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#
        )

        let (events, turn, _) = try await driveProcessor(sse: sse)

        #expect(finalizedEvents(in: events).isEmpty)
        #expect(emptyEvents(in: events).count == 1)
        #expect(turn.text.isEmpty)
        #expect(turn.resolvedToolCalls().isEmpty)
    }

    @Test("sends section started events")
    func sendsSectionStartedEvents() async throws {
        let sse = makeSSE(
            #"{"id":"c-1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"reasoning_content":"Thinking..."},"finish_reason":null}]}"#,
            #"{"id":"c-1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"Answer"},"finish_reason":null}]}"#,
            #"{"id":"c-1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#
        )

        let (events, _, _) = try await driveProcessor(sse: sse)

        let sections = events.filter {
            if case .output(.sectionStarted(_, _)) = $0 { return true }
            return false
        }
        #expect(sections.count == 2)
    }

    // MARK: - [DONE] sentinel

    @Test("handles [DONE] sentinel after content")
    func handlesDoneSentinel() async throws {
        let sse = makeSSE(
            #"{"id":"c-1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"Hi"},"finish_reason":null}]}"#
        ) + "data: [DONE]\n\n"

        let (events, turn, _) = try await driveProcessor(sse: sse)

        #expect(finalizedEvents(in: events).count == 1)
        #expect(turn.text == "Hi")
    }

    @Test("skips malformed JSON chunks gracefully")
    func skipsMalformedChunks() async throws {
        let sse = makeSSE(
            "NOT VALID JSON",
            #"{"id":"c-1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"Still works"},"finish_reason":null}]}"#,
            #"{"id":"c-1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#
        )

        let (events, turn, processor) = try await driveProcessor(sse: sse)

        #expect(finalizedEvents(in: events).count == 1)
        #expect(turn.text == "Still works")
        #expect(processor.skippedChunkCount == 1)
        #expect(processor.decodedChunkCount == 2)
    }

    @Test("skips empty data lines")
    func skipsEmptyDataLines() async throws {
        let sse = "data: \n\ndata:   \n\n" +
            makeSSE(
                #"{"id":"c-1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"X"},"finish_reason":"stop"}]}"#
            )

        let (events, turn, _) = try await driveProcessor(sse: sse)

        #expect(finalizedEvents(in: events).count == 1)
        #expect(turn.text == "X")
    }

    // MARK: - Usage tracking

    @Test("tracks usage from chunk with usage field")
    func tracksUsage() async throws {
        let sse = makeSSE(
            #"{"id":"c-1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"A"},"finish_reason":"stop"}],"usage":{"prompt_tokens":100,"completion_tokens":50,"total_tokens":150}}"#
        )

        let (_, _, processor) = try await driveProcessor(sse: sse)

        #expect(processor.lastUsage?.promptTokens == 100)
        #expect(processor.lastUsage?.completionTokens == 50)
        #expect(processor.lastUsage?.totalTokens == 150)
    }

    @Test("does not track usage when no usage field")
    func noUsageWhenNotPresent() async throws {
        let sse = makeSSE(
            #"{"id":"c-1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"A"},"finish_reason":"stop"}]}"#
        )

        let (_, _, processor) = try await driveProcessor(sse: sse)

        #expect(processor.lastUsage == nil)
    }

    // MARK: - Stream flags

    @Test("streamStarted is false when no content received")
    func streamNotStartedWhenNoContent() async throws {
        let sse = makeSSE(
            #"{"id":"c-1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#
        )

        let (_, _, processor) = try await driveProcessor(sse: sse)

        #expect(processor.streamStarted == false)
    }

    @Test("streamStarted is true when content received")
    func streamStartedWhenContentReceived() async throws {
        let sse = makeSSE(
            #"{"id":"c-1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"Hi"},"finish_reason":"stop"}]}"#
        )

        let (_, _, processor) = try await driveProcessor(sse: sse)

        #expect(processor.streamStarted == true)
    }

    @Test("streamStarted is true when reasoning received")
    func streamStartedWhenReasoningReceived() async throws {
        let sse = makeSSE(
            #"{"id":"c-1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"reasoning_content":"Hmm..."},"finish_reason":"stop"}]}"#
        )

        let (_, _, processor) = try await driveProcessor(sse: sse)

        #expect(processor.streamStarted == true)
    }
}
