# Headless test mode — end-to-end testing without a terminal

## Problem

There is currently no way to write an end-to-end test that exercises a full
chat turn (user types a message, agent streams a response, tools run, transcript
is rendered) without standing up Slate in a real terminal. This means:

1. **Integration bugs between components are discovered manually** — the
   "zombie tray text" bug (see `queued-message-zombie-bug.md`) survived because
   no test covered the `SubmitCoordinator` → `HostSubmitState.apply` →
   `SlateChatHost` integration path.

2. **Transcript rendering regressions require visual inspection** — if
   markdown handling changes, the only way to verify the transcript looks
   correct is to run the TUI and scroll through the output.

3. **The feedback loop for render-related changes is slow** — build, run the
   TUI, type prompts, inspect output visually, repeat.

## Proposed: `ChatDriver`

A headless driver that runs the full chat pipeline (coordinator + transcript
controller + renderer) with programmable input and inspectable output.

```swift
// ScribeCLI/ChatDriver.swift

/// Runs a chat session headlessly — no terminal, no Slate.
///
/// Input is provided programmatically; transcript snapshots are collected
/// after each event.  Designed for testing and maybe future non-TUI modes
/// (e.g., a web UI, a REPL mode).
struct ChatDriver {
    /// Configuration for a headless run.
    struct Config {
        var agent: ScribeAgent
        var theme: CLITheme
        var initialMessages: [Components.Schemas.ChatMessage] = []
        /// If true, collect a RenderOutput snapshot after every TranscriptEvent.
        var captureEveryEvent: Bool = true
    }

    /// Run the chat loop with the given input lines.  Returns a history of
    /// transcript states and a final result.
    ///
    /// The input stream is consumed until the coordinator exits (EOF, "exit"
    /// command, or error).  After each TranscriptEvent, `captureEveryEvent`
    /// controls whether a full `RenderOutput` snapshot is appended to the
    /// history.
    func run(
        config: Config,
        input: [String],
        log: Logger
    ) async throws -> RunResult
}

struct RunResult {
    /// The final coordinator result.
    var coordinatorResult: CoordinatorResult

    /// Transcript snapshots after each event (if captureEveryEvent was true).
    var transcriptHistory: [TranscriptSnapshot]

    /// The final transcript.
    var finalTranscript: [TLine]

    /// The final render output.
    var finalRender: RenderOutput
}

struct TranscriptSnapshot {
    var event: TranscriptEvent
    var completedLines: [TLine]
    var streamingOpenLine: TLine?
}
```

## Implementation sketch

`ChatDriver.run()` wires together the extracted components without Slate:

```swift
func run(config: Config, input: [String], log: Logger) async throws -> RunResult {
    let persistence = SessionPersistence.noop
    var transcriptController = TranscriptController()
    let adapter = MarkdownToSlateAdapter(theme: config.theme)
    let markdownRenderer = SwiftMarkdownRenderer()

    var history: [TranscriptSnapshot] = []
    var events: [HostEvent] = []

    let coordinator = ChatCoordinator(
        agent: config.agent,
        persistence: persistence,
        eventSink: { events.append($0) },
        log: log
    )

    // Feed input lines to the coordinator
    let (inputStream, inputContinuation) = AsyncStream<String>.makeStream()
    for line in input { inputContinuation.yield(line) }
    inputContinuation.yield("exit")
    inputContinuation.finish()

    let coordinatorResult = await coordinator.run(
        input: inputStream,
        interruptFlag: ModelTurnInterruptFlag()
    )

    // Drain events through the transcript controller (simulating the host's
    // drainIncomingEvents + render loop, but without Slate)
    for event in events {
        switch event {
        case .transcript(let te):
            _ = transcriptController.apply(te, theme: config.theme, renderer: markdownRenderer)
            if config.captureEveryEvent {
                history.append(TranscriptSnapshot(
                    event: te,
                    completedLines: transcriptController.completedLines,
                    streamingOpenLine: transcriptController.streamingOpenLine
                ))
            }
        case .modelTurnRunning, .coordinatorFinished:
            break // No transcript impact
        }
    }

    // Build final render frame
    let finalRender = buildFrame(state: RenderState(
        inputBuffer: "",
        modelBusy: false,
        queuedTrayText: nil,
        banner: nil,
        usage: nil,
        completedTranscript: transcriptController.completedLines,
        streamingOpenLine: nil,
        transcriptGeneration: transcriptController.generation,
        flattenCache: TranscriptLayout.FlattenCache(),
        llmWaitAnimationFrame: 0,
        viewport: TranscriptViewport(),
        terminalCols: 120,
        terminalRows: 40
    ), theme: config.theme)

    return RunResult(
        coordinatorResult: coordinatorResult,
        transcriptHistory: history,
        finalTranscript: transcriptController.completedLines,
        finalRender: finalRender
    )
}
```

## Example tests

```swift
@Test func headlessFullTurnProducesCorrectTranscript() async throws {
    let transport = FakeClientTransport(statusCode: 200, responseBodyChunks: [
        sseChunk(#"{"choices":[{"delta":{"content":"Hello, world!"}}]}"#),
        doneChunk(),
    ])
    let client = Client(serverURL: URL(string: "http://test")!, transport: transport)
    let agent = ScribeAgent(
        client: client,
        model: "test",
        systemPrompt: "You are a test agent.",
        workingDirectory: ScribeFilePath("/tmp")
    )

    let result = try await ChatDriver().run(
        config: ChatDriver.Config(agent: agent),
        input: ["say hello"],
        log: testLogger
    )

    // Final transcript should contain user message and assistant response
    let transcriptText = result.finalTranscript
        .flatMap { $0.spans }
        .map { $0.text }
        .joined()

    #expect(transcriptText.contains("you:"))
    #expect(transcriptText.contains("Hello, world!"))
}

@Test func headlessToolRoundCreatesCorrectTranscript() async throws {
    let toolChunks = [
        sseChunk(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"fake_tool","arguments":"{}"}}]}}]}"#),
        doneChunk(),
    ]
    let replyChunks = [
        sseChunk(#"{"choices":[{"delta":{"content":"done"}}]}"#),
        doneChunk(),
    ]
    let transport = FakeClientTransport(
        statusCode: 200,
        responseBodyChunksForCall: [toolChunks, replyChunks]
    )
    let client = Client(serverURL: URL(string: "http://test")!, transport: transport)
    let agent = ScribeAgent(
        client: client,
        model: "test",
        systemPrompt: "You are a test agent.",
        tools: [FakeTool()],
        workingDirectory: ScribeFilePath("/tmp")
    )

    let result = try await ChatDriver().run(
        config: ChatDriver.Config(agent: agent),
        input: ["use the tool"],
        log: testLogger
    )

    // Should contain tool round header
    let transcriptText = result.finalTranscript
        .flatMap { $0.spans }
        .map { $0.text }
        .joined()
    #expect(transcriptText.contains("tool round 1"))
    #expect(transcriptText.contains("fake_tool"))
}
```

## Dependencies

`ChatDriver` depends on the other extractions being done first:

| Dependency | Status |
|---|---|
| `TranscriptController` | Proposed in `transcript-controller.md` |
| `ChatCoordinator` | Proposed in `chat-coordinator.md` |
| `buildFrame` | Proposed in `host-render-loop-extraction.md` |
| `MarkdownToSlateAdapter` | Proposed in `markdown-output-decoupling.md` |

Without those, `ChatDriver` would have to duplicate the transcript-building
and frame-rendering logic, defeating the purpose.

## Benefits

1. **End-to-end test without a terminal** — the entire chat pipeline from user
   input to rendered transcript is exercised in XCTest.

2. **Transcript golden-file tests** — render a known conversation to `[TLine]`
   and compare against a stored golden file.  Regressions in markdown rendering,
   tool output formatting, error display, or streaming-vs-batch drift are
   caught automatically.

3. **Basis for non-TUI modes** — if Scribe ever gets a web UI, a REPL mode,
   or an IDE plugin, `ChatDriver` provides the headless chat loop that those
   modes can plug into.

4. **Performance regression testing** — `ChatDriver` can measure event-to-frame
   latency and flag regressions in the render pipeline.

## Source changes

| File | Change |
|---|---|
| **New:** `ScribeCLI/ChatDriver.swift` | Headless driver |
| **New:** `Tests/ScribeCLITests/ChatDriverTests.swift` | End-to-end tests |
| **New:** `Tests/ScribeCLITests/TranscriptGoldenTests.swift` | Golden-file transcript tests |
