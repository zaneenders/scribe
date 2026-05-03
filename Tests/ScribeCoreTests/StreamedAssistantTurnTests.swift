import Foundation
import ScribeCore
import ScribeLLM
import Testing

/// Tests for the chunk-accumulation logic in `StreamedAssistantTurn`,
/// which assembles streamed deltas into final text, reasoning, and tool calls.
@Suite
struct StreamedAssistantTurnTests {

    // MARK: - Helpers

    private func makeChunk(
        content: String? = nil,
        reasoningContent: String? = nil,
        reasoning: String? = nil,
        finishReason: String? = nil,
        toolDeltas: [Components.Schemas.ToolCallDelta]? = nil,
        index: Int? = nil
    ) -> Components.Schemas.ChatCompletionChunk {
        let delta = Components.Schemas.ChoiceDelta(
            role: nil,
            content: content,
            reasoningContent: reasoningContent,
            reasoning: reasoning,
            toolCalls: toolDeltas
        )
        let choice = Components.Schemas.ChunkChoice(
            index: index ?? 0,
            delta: delta,
            finishReason: finishReason
        )
        return Components.Schemas.ChatCompletionChunk(
            id: "chunk-1",
            object: "chat.completion.chunk",
            choices: [choice]
        )
    }

    private func makeToolDelta(
        index: Int? = nil,
        id: String? = nil,
        name: String? = nil,
        arguments: String? = nil
    ) -> Components.Schemas.ToolCallDelta {
        let fn = Components.Schemas.ToolCallDelta.FunctionPayload(
            name: name,
            arguments: arguments
        )
        return Components.Schemas.ToolCallDelta(
            index: index,
            id: id,
            _type: "function",
            function: fn
        )
    }

    // MARK: - Text accumulation

    @Test func accumulatesTextAcrossMultipleChunks() {
        var turn = StreamedAssistantTurn()
        turn.apply(chunk: makeChunk(content: "hello"))
        turn.apply(chunk: makeChunk(content: " world"))
        #expect(turn.text == "hello world")
    }

    @Test func textStaysEmptyWhenNoContentDeltasArrive() {
        var turn = StreamedAssistantTurn()
        turn.apply(chunk: makeChunk(content: nil))
        turn.apply(chunk: makeChunk(content: nil))
        #expect(turn.text.isEmpty)
    }

    @Test func ignoresEmptyContentStrings() {
        var turn = StreamedAssistantTurn()
        turn.apply(chunk: makeChunk(content: ""))
        turn.apply(chunk: makeChunk(content: "real"))
        #expect(turn.text == "real")
    }

    // MARK: - Reasoning accumulation

    @Test func accumulatesReasoningContentField() {
        var turn = StreamedAssistantTurn()
        turn.apply(chunk: makeChunk(reasoningContent: "think-"))
        turn.apply(chunk: makeChunk(reasoningContent: "more"))
        #expect(turn.reasoningText == "think-more")
    }

    @Test func accumulatesReasoningField() {
        var turn = StreamedAssistantTurn()
        turn.apply(chunk: makeChunk(reasoning: "reason-"))
        turn.apply(chunk: makeChunk(reasoning: "deep"))
        #expect(turn.reasoningText == "reason-deep")
    }

    @Test func accumulatesReasoningFromBothFields() {
        var turn = StreamedAssistantTurn()
        turn.apply(chunk: makeChunk(reasoningContent: "rc-", reasoning: "r-"))
        // Both fields are iterated; order matters — reasoningContent first then reasoning
        // based on AgentHarness code: [delta.reasoningContent, delta.reasoning].compactMap...
        #expect(turn.reasoningText == "rc-r-")
    }

    @Test func ignoresEmptyReasoningStrings() {
        var turn = StreamedAssistantTurn()
        turn.apply(chunk: makeChunk(reasoningContent: "", reasoning: ""))
        turn.apply(chunk: makeChunk(reasoningContent: "valid"))
        #expect(turn.reasoningText == "valid")
    }

    // MARK: - Finish reason

    @Test func capturesFinishReasonFromChunk() {
        var turn = StreamedAssistantTurn()
        #expect(turn.finishReason == nil)
        turn.apply(chunk: makeChunk(content: "last", finishReason: "stop"))
        #expect(turn.finishReason == "stop")
    }

    @Test func lastFinishReasonWinsWhenMultipleChoices() {
        var turn = StreamedAssistantTurn()
        let delta1 = Components.Schemas.ChoiceDelta(content: "a")
        let delta2 = Components.Schemas.ChoiceDelta(content: "b")
        let chunk = Components.Schemas.ChatCompletionChunk(
            id: "c",
            choices: [
                Components.Schemas.ChunkChoice(index: 0, delta: delta1, finishReason: "length"),
                Components.Schemas.ChunkChoice(index: 1, delta: delta2, finishReason: "stop"),
            ]
        )
        turn.apply(chunk: chunk)
        #expect(turn.finishReason == "stop")
    }

    // MARK: - Tool calls: simple assembly

    @Test func assemblesSingleToolCallFromStreamedDeltas() {
        var turn = StreamedAssistantTurn()
        // First chunk: id + name
        turn.apply(chunk: makeChunk(toolDeltas: [
            makeToolDelta(index: 0, id: "call_1", name: "shell")
        ]))
        // Second chunk: arguments part 1
        turn.apply(chunk: makeChunk(toolDeltas: [
            makeToolDelta(index: 0, arguments: "{\"com")
        ]))
        // Third chunk: arguments part 2
        turn.apply(chunk: makeChunk(toolDeltas: [
            makeToolDelta(index: 0, arguments: "mand\":\"ls\"}")
        ]))

        let resolved = turn.resolvedToolCalls()
        #expect(resolved.count == 1)
        #expect(resolved[0].id == "call_1")
        #expect(resolved[0].name == "shell")
        #expect(resolved[0].arguments == "{\"command\":\"ls\"}")
    }

    @Test func assemblesMultipleToolCallsInParallel() {
        var turn = StreamedAssistantTurn()
        turn.apply(chunk: makeChunk(toolDeltas: [
            makeToolDelta(index: 0, id: "c0", name: "shell", arguments: "{\"cmd\":\"a\"}"),
            makeToolDelta(index: 1, id: "c1", name: "read_file", arguments: "{\"path\":\"f\"}"),
        ]))
        let resolved = turn.resolvedToolCalls()
        #expect(resolved.count == 2)
        #expect(resolved[0].name == "shell")
        #expect(resolved[1].name == "read_file")
    }

    // MARK: - Tool calls: edge cases

    @Test func toolCallMissingIdIsNotResolved() {
        var turn = StreamedAssistantTurn()
        turn.apply(chunk: makeChunk(toolDeltas: [
            makeToolDelta(index: 0, id: nil, name: "shell", arguments: "{}")
        ]))
        #expect(turn.resolvedToolCalls().isEmpty)
    }

    @Test func toolCallMissingNameIsNotResolved() {
        var turn = StreamedAssistantTurn()
        turn.apply(chunk: makeChunk(toolDeltas: [
            makeToolDelta(index: 0, id: "call_1", name: nil, arguments: "{}")
        ]))
        #expect(turn.resolvedToolCalls().isEmpty)
    }

    @Test func toolCallWithEmptyIdIsResolvedWhenNamePresent() {
        // Per the code: `guard let id = t.id, let name = t.name` — empty string is truthy in Swift
        var turn = StreamedAssistantTurn()
        turn.apply(chunk: makeChunk(toolDeltas: [
            makeToolDelta(index: 0, id: "", name: "shell", arguments: "{}")
        ]))
        let resolved = turn.resolvedToolCalls()
        #expect(resolved.count == 1)
        #expect(resolved[0].id == "")
    }

    @Test func toolCallDefaultIndexIsZero() {
        var turn = StreamedAssistantTurn()
        // Two tool deltas with no explicit index both default to 0, so they merge
        turn.apply(chunk: makeChunk(toolDeltas: [
            makeToolDelta(index: nil, id: "call_1", name: "shell"),
            makeToolDelta(index: nil, arguments: "{}"),
        ]))
        let resolved = turn.resolvedToolCalls()
        #expect(resolved.count == 1)
    }

    @Test func emptyChunkWithNilChoicesDoesNothing() {
        var turn = StreamedAssistantTurn()
        let chunk = Components.Schemas.ChatCompletionChunk(
            id: "empty",
            choices: nil
        )
        turn.apply(chunk: chunk)
        #expect(turn.text.isEmpty)
        #expect(turn.reasoningText.isEmpty)
        #expect(turn.resolvedToolCalls().isEmpty)
    }

    @Test func emptyChoicesArrayDoesNothing() {
        var turn = StreamedAssistantTurn()
        let chunk = Components.Schemas.ChatCompletionChunk(
            id: "empty",
            choices: []
        )
        turn.apply(chunk: chunk)
        #expect(turn.text.isEmpty)
        #expect(turn.resolvedToolCalls().isEmpty)
    }

    // MARK: - Interleaved content + tool calls

    @Test func interleavesTextAndToolCalls() {
        var turn = StreamedAssistantTurn()
        turn.apply(chunk: makeChunk(content: "Let me check", toolDeltas: [
            makeToolDelta(index: 0, id: "call_1", name: "shell", arguments: "{\"cmd\":\"ls\"}")
        ]))
        #expect(turn.text == "Let me check")
        #expect(turn.resolvedToolCalls().count == 1)
    }

    // MARK: - Tool calls: sorted by index

    @Test func resolvedToolCallsAreSortedByIndex() {
        var turn = StreamedAssistantTurn()
        turn.apply(chunk: makeChunk(toolDeltas: [
            makeToolDelta(index: 2, id: "c2", name: "write_file", arguments: "{}"),
            makeToolDelta(index: 0, id: "c0", name: "shell", arguments: "{}"),
            makeToolDelta(index: 1, id: "c1", name: "read_file", arguments: "{}"),
        ]))
        let resolved = turn.resolvedToolCalls()
        #expect(resolved.map(\.id) == ["c0", "c1", "c2"])
    }
}
