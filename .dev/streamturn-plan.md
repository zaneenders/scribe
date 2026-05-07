# StreamTurn — ScribeAgent API refactoring plan

## Goal

Reduce `ScribeAgent` to **one execution primitive** — `streamTurn` — that serves the CLI repl, the IPC one-shot path, and remote servers (shape-tree) forwarding token streams to clients.

## Current state

```
runInteractive ──┐
                 ├──► runTurn(inout:onEvent:) ──► AgentLoop.runModelTurn(inout:onEvent:)
runIPC ──────────┘
```

`runTurn` is the callback-based, `inout`-driven bottleneck. Every consumer must work through a closure. Streaming to a remote client is impossible without building an ad-hoc bridge.

## Target state

```
runInteractive ──┐
                 ├──► streamTurn(messages:) ──► AgentLoop internals
runIPC ──────────┤
shape-tree ──────┘
```

One method. Every consumer iterates the same `AsyncStream<TranscriptEvent>` and awaits the same `Task<TurnResult, Error>` for the final state.

---

## New types (ScribeCore)

```swift
// Sources/ScribeCore/Agent/TurnStream.swift

/// A live stream of transcript events plus a deferred result.
public struct TurnStream: Sendable {
    /// Yields events as the turn progresses (text deltas, tool calls, usage, errors).
    public let events: AsyncStream<TranscriptEvent>

    /// Await this for the final messages + outcome. The event stream
    /// finishes before (or concurrently with) this task.
    public let result: Task<TurnResult, Error>
}

/// The final state after a turn completes.
public struct TurnResult: Sendable {
    public let messages: [Components.Schemas.ChatMessage]
    public let outcome: ModelTurnOutcome
}
```

## New method (ScribeAgent)

```swift
// Sources/ScribeCore/Agent/ScribeAgent.swift

/// The single execution primitive. Takes an owned copy of messages,
/// returns a live stream of events plus a Task that resolves when
/// the turn finishes.
///
/// Cancelling the result task propagates to AgentLoop's shouldAbortTurn
/// pattern (caller is responsible for wiring this if needed).
public func streamTurn(
    messages: [Components.Schemas.ChatMessage],
    log: Logger,
    maxToolRounds: Int = .max,
    shouldAbortTurn: @escaping @Sendable () -> Bool = { false }
) -> TurnStream {
    let (stream, continuation) = AsyncStream<TranscriptEvent>.makeStream()
    var mutable = messages

    let task = Task {
        defer { continuation.finish() }
        let outcome = try await loop.runModelTurn(
            messages: &mutable,
            logger: log,
            onEvent: { continuation.yield($0) },
            maxToolRounds: maxToolRounds,
            shouldAbortTurn: shouldAbortTurn
        )
        return TurnResult(messages: mutable, outcome: outcome)
    }

    return TurnStream(events: stream, result: task)
}
```

---

## What gets removed

| Removed | Why |
|---|---|
| `runTurn(messages:inout:onEvent:...)` | Replaced by `streamTurn` |
| The `onEvent` callback parameter | Replaced by `for await event in ts.events` |
| `inout messages` from the public API | Owned value in, owned value out via `TurnResult.messages` |

---

## Consumer rewrites

### 1. `runInteractive` (CLI repl)

Before:
```swift
let outcome = try await runTurn(
    messages: &history,
    log: log,
    onEvent: wrappedOnEvent,
    shouldAbortTurn: shouldAbortTurn
)
// history mutated in-place
```

After:
```swift
let ts = streamTurn(messages: history, log: log, shouldAbortTurn: shouldAbortTurn)
for await event in ts.events {
    if case .usage(let usage, _) = event { tracker.accumulate(usage: usage) }
    onEvent(event)  // terminal rendering
}
let result = try await ts.result.value
history = result.messages
let outcome = result.outcome
```

### 2. `runIPC` (subprocess one-shot)

Before:
```swift
let outcome = try await runTurn(
    messages: &history, log: log, onEvent: onEvent
)
let text = ChatHistory.lastAssistantText(from: history) ?? ""
```

After:
```swift
let ts = streamTurn(messages: history, log: log)
Task { for await event in ts.events { onEvent(event) } }
let result = try await ts.result.value
let text = ChatHistory.lastAssistantText(from: result.messages) ?? ""
```

### 3. ShapeTree server (`/sessions/{id}/completions` → SSE)

Before:
```swift
_ = try await session.agent.runTurn(
    messages: &session.messages, log: turnLog, onEvent: { _ in }
)
let text = ChatHistory.lastAssistantText(from: session.messages) ?? ""
return .ok(.init(body: .json(CompletionResponse(assistant: text))))
```

After:
```swift
let ts = session.agent.streamTurn(messages: session.messages, log: turnLog)

let byteStream = AsyncThrowingStream<[UInt8], Error> { cont in
    let producer = Task {
        for await event in ts.events {
            switch event {
            case .appendAssistantText(let section, let text):
                cont.yield(encodeSSE(section: section, text: text))
            case .toolInvocation(let name, _, let output):
                cont.yield(encodeSSE(tool: name, output: output))
            case .usage(let usage, let tps):
                cont.yield(encodeSSE(usage: usage, tps: tps))
            case .harnessError(let err):
                cont.yield(encodeSSE(error: err))
            case .turnInterrupted:
                cont.yield(encodeSSE(interrupted: true))
            default:
                break
            }
        }
        let result = try await ts.result.value
        await store.setMessages(id, messages: result.messages)
        cont.yield(Array("data: [DONE]\n\n".utf8))
        cont.finish()
    }
    cont.onTermination = { @Sendable _ in producer.cancel() }
}
return .ok(.init(body: .textEventStream(HTTPBody(byteStream, ...))))
```

---

## Final ScribeAgent surface

| Method | Purpose |
|---|---|
| `streamTurn(messages:log:...) -> TurnStream` | **The primitive.** Everything flows through this. |
| `runInteractive(onEvent:readUserLine:...)` | REPL loop. Refactored to call `streamTurn` internally. |
| `runIPC(request:onEvent:log:) -> ScribeAgentResponse` | One-shot JSON. Refactored to call `streamTurn` internally. |

Three methods, one execution path. No `inout`, no `onEvent` callback on the primitive.

---

## Implementation order

1. ✅ **Add `TurnStream` + `TurnResult`** — new file `Sources/ScribeCore/Agent/TurnStream.swift`
2. ✅ **Add `streamTurn` to `ScribeAgent`** — calls existing `loop.runModelTurn` internally
3. ✅ **Delete `runTurn`** — removed the method and its doc comment
4. ✅ **Rewrite `runInteractive`** — replaced `runTurn(&history, onEvent:)` with `streamTurn` + `for await`
5. ✅ **Rewrite `runIPC`** — same pattern
6. ✅ **Update tests** — `ScribeAgentTests` uses `streamTurn` instead of `runTurn`; `AgentLoopTests` and `AgentHarnessTests` unchanged (they call lower-level APIs directly)
7. ✅ **Update shape-tree** — `ShapeTreeHandler.runCompletion` uses `streamTurn` (batch mode — drains events, awaits result)
8. **Future: shape-tree streaming endpoint** — new SSE endpoint that iterates `ts.events` and serializes to `text/event-stream` bytes
