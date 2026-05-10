# Extract a `ChatCoordinator` actor

## Problem

The coordinator task in `SlateChatHost.run()` is an ~110-line closure embedded
inside a `Task { [captures...] in ... }` block. It:

- Creates and owns the `ScribeAgent`
- Loops reading user lines from a `UserLineGate`
- Dispatches turns to `ScribeAgent.prompt()`
- Persists messages to disk after each turn
- Enqueues `HostEvent` values to the host's event queue

This closure is impossible to test without standing up the full Slate host.
It also forces `SlateChatHost` to own the `ScribeAgent` lifecycle details
(initial message preparation, metadata writing, token tracking).

## What to extract

```swift
/// Coordinates the chat loop: reads user input, runs agent turns,
/// persists sessions, and emits events to the host.
///
/// Owns the ScribeAgent and TokenTracker. Communicates with the host
/// exclusively through an AsyncStream of input lines and a closure
/// that sinks HostEvent values.
actor ChatCoordinator {
    private let agent: ScribeAgent
    private let persistence: SessionPersistence
    private let eventSink: (HostEvent) -> Void
    private let log: Logger

    /// Initialize with everything the coordinator needs.
    init(
        configuration: ScribeConfig,
        systemPrompt: String,
        initialMessages: [Components.Schemas.ChatMessage],
        persistence: SessionPersistence,
        eventSink: @escaping @Sendable (HostEvent) -> Void,
        log: Logger
    ) throws

    /// Run the prompt loop. Reads lines from `input` until nil (EOF) or
    /// "exit". Returns the final message count.
    ///
    /// - Parameter interruptFlag: Cooperative abort flag checked before each
    ///   HTTP call and tool invocation.
    func run(
        input: AsyncStream<String>,
        interruptFlag: ModelTurnInterruptFlag
    ) async -> CoordinatorResult
}

struct CoordinatorResult {
    let finalMessageCount: Int
    let reason: StopReason
}

enum StopReason: Sendable {
    case eof
    case exitCommand
    case error(Error)
}
```

## Session persistence as a separate concern

The current host intermixes `ChatSessionStore` calls (save metadata, append
messages) with coordinator logic. Extract persistence into a thin actor or
struct so the coordinator stays focused on the prompt loop:

```swift
/// Encapsulates all session file I/O so the coordinator doesn't know about
/// URLs, metadata schemas, or file formats.
actor SessionPersistence {
    private let url: URL
    let sessionId: UUID
    let createdAt: Date

    /// Write metadata (new sessions only — no-op if already written).
    func writeMetadataOnce(model: String, cwd: String, baseURL: String) throws

    /// Append messages to the session file.
    func append(_ messages: [Components.Schemas.ChatMessage]) throws
}
```

## How the host uses it

```swift
// In SlateChatHost.run():
let persistence = SessionPersistence(
    url: sessionPersistenceURL,
    sessionId: sessionId,
    createdAt: sessionCreatedAt
)
let coordinator = try ChatCoordinator(
    configuration: configuration,
    systemPrompt: systemPrompt,
    initialMessages: resumeMessages,
    persistence: persistence,
    eventSink: { [eventQueue] event in eventQueue.enqueue(event) },
    log: log
)

// Convert the gate to an AsyncStream for the coordinator
let (inputStream, inputContinuation) = AsyncStream<String>.makeStream()
// Bridge gate.nextLine() → inputContinuation.yield(line)

coordinatorTask = Task {
    let result = await coordinator.run(
        input: inputStream,
        interruptFlag: modelInterruptFlag
    )
    eventQueue.enqueue(.coordinatorFinished)
}
```

## Testability

With a `FakeClientTransport` (already exists in `ScribeAgentTests`) and a
no-op `SessionPersistence`, the coordinator can be tested end-to-end:

```swift
@Test func coordinatorCompletesSimpleTurn() async throws {
    let transport = FakeClientTransport(statusCode: 200, responseBodyChunks: [
        sseChunk(#"{"choices":[{"delta":{"content":"hello"}}]}"#),
        doneChunk(),
    ])
    let client = Client(serverURL: URL(string: "http://test")!, transport: transport)
    let agent = ScribeAgent(client: client, model: "test", systemPrompt: "You are a test agent.", ...)
    
    var events: [HostEvent] = []
    let coordinator = ChatCoordinator(
        agent: agent,
        persistence: .noop,
        eventSink: { events.append($0) },
        log: testLogger
    )
    
    let (input, cont) = AsyncStream<String>.makeStream()
    cont.yield("hello")
    cont.yield("exit")
    cont.finish()
    
    let result = await coordinator.run(input: input, interruptFlag: ModelTurnInterruptFlag())
    
    #expect(result.reason == .exitCommand)
    #expect(events.contains(where: { /* .transcript(.userSubmitted("hello")) */ }))
}
```

## Benefits

1. **Coordinator is testable without Slate** — the fake transport from
   `ScribeAgentTests` is reused; only an `AsyncStream<String>` and an event
   collector are needed.

2. **Session persistence is testable in isolation** — `SessionPersistence` can
   be tested with temporary directories without involving the agent or the TUI.

3. **SlateChatHost shrinks by ~150 lines** — the closure body moves out, and
   the host only manages the bridge between gate and stream, plus event
   draining.

4. **Separation of concerns** — the host owns *presentation* (Slate, rendering,
   input handling) and the coordinator owns *conversation* (agent, persistence,
   token tracking).

## Source changes

| File | Change | Status |
|---|---|---|
| **New:** `ScribeCLI/SlateChat/ChatCoordinator.swift` | New actor (276 lines) | ✅ Done |
| **New:** `ScribeCLI/SlateChat/SessionPersistence.swift` | Extract persistence (40 lines) | ✅ Done |
| **Modify:** `SlateChatHost.swift` | Replace embedded closure with coordinator; remove agent ownership | ✅ Done (1032→889, −143 lines) |
| **New:** `Tests/ScribeCLITests/ChatCoordinatorTests.swift` | Coordinator tests (441 lines) | ✅ Done |
| **New:** `Tests/ScribeCLITests/SessionPersistenceTests.swift` | Persistence tests (86 lines) | ✅ Done |

**Note:** `ModelTurnInterruptFlag`, `HostEvent`, `CoordinatorResult`, and `StopReason` were moved from `SlateChatHost.swift` into `ChatCoordinator.swift` since they are shared between the coordinator and host.
