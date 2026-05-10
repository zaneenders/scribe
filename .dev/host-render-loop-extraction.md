# Extract the host render loop into a pure function

## Problem

The render loop inside `SlateChatHost.run()` (the `onEvent` closure passed to
`slate.subscribe`) is ~200 lines that mix:

1. **Stdin dispatch** — `TerminalInputHandler.handle(chunk)` → `SubmitCoordinator` → `applySubmitEffect`
2. **Event draining** — `eventQueue.drain()` → `handleTranscriptEvent`
3. **Auto-flush** — `submitCoordinator.handleModelTurnEnd()` on busy→idle transition
4. **Frame building** — `FlattenCache.flatten()` + `SlateChatRenderer.transcriptContentRows()` + `viewport.resolve()` + `SlateChatRenderer.render()`

Items 1–3 are side-effectful (they mutate state and communicate with the
coordinator). Item 4 is a pure computation from state to pixels. The mixture
makes it impossible to test any part of the render pipeline without standing up
Slate and feeding real stdin bytes.

## Key insight

The `onEvent` closure does three sequential jobs every frame:

```
stdin bytes → [input actions] → submit effects (mutate host state)
                               → drain coordinator events (mutate transcript)
                               → build frame from current state (pure)
                               → write frame to grid (Slate side-effect)
```

The submit-effects and event-draining are already testable in isolation
(`SubmitCoordinator`, `HostSubmitState.apply`, proposed `TranscriptController`).
The frame-building step should be too.

## What to extract: `buildFrame`

```swift
/// All the state needed to render one frame.  Pure value type.
struct RenderState: Equatable, Sendable {
    var inputBuffer: String
    var modelBusy: Bool
    var queuedTrayText: String?
    var banner: BannerSnapshot?
    var usage: UsageHUDSnapshot?
    var completedTranscript: [TLine]
    var streamingOpenLine: TLine?
    var transcriptGeneration: Int
    var flattenCache: TranscriptLayout.FlattenCache
    var llmWaitAnimationFrame: Int
    var viewport: TranscriptViewport
    var terminalCols: Int
    var terminalRows: Int
}

/// The output of one frame render — everything needed to paint the screen.
struct RenderOutput: Equatable, Sendable {
    /// Flattened transcript lines starting at `transcriptTailStart`.
    var flatTranscript: [TLine]
    var transcriptTailStart: Int
    var viewportFollowingLive: Bool
    var grid: [[StyledSpan]]  // Semantic description; not Slate-specific
    var updatedFlattenCache: TranscriptLayout.FlattenCache
    var updatedViewport: TranscriptViewport
}

/// Pure function — no side effects, no Slate dependency.
func buildFrame(
    state: RenderState,
    theme: CLITheme
) -> RenderOutput
```

The rendering is pure:

```swift
func buildFrame(state: RenderState, theme: CLITheme) -> RenderOutput {
    var viewport = state.viewport
    
    // 1. Flatten transcript (pure)
    var cache = state.flattenCache
    let flatLines = TranscriptLayout.FlattenCache.flatten(
        cache: &cache,
        completed: state.completedTranscript,
        open: state.streamingOpenLine,
        width: state.terminalCols,
        generation: state.transcriptGeneration
    )
    
    // 2. Calculate content rows (pure)
    let contentRows = SlateChatRenderer.transcriptContentRows(
        cols: state.terminalCols,
        rows: state.terminalRows,
        banner: state.banner,
        usage: state.usage,
        inputLine: state.inputBuffer,
        waitingForLLM: state.modelBusy,
        queuedTrayText: state.queuedTrayText
    )
    
    // 3. Resolve viewport (pure)
    let tailStart = viewport.resolve(flatCount: flatLines.count, contentRows: contentRows)
    
    // 4. Build semantic grid (pure — no SlateCell, just StyledSpan arrays)
    let grid = SlateChatRenderer.buildGrid(
        cols: state.terminalCols,
        rows: state.terminalRows,
        flattenedTranscript: flatLines,
        transcriptTailStart: tailStart,
        banner: state.banner,
        usage: state.usage,
        inputLine: state.inputBuffer,
        llmWaitAnimationFrame: state.llmWaitAnimationFrame,
        waitingForLLM: state.modelBusy,
        queuedTrayText: state.queuedTrayText,
        theme: theme
    )
    
    return RenderOutput(
        flatTranscript: flatLines,
        transcriptTailStart: tailStart,
        viewportFollowingLive: viewport.followingLive,
        grid: grid,
        updatedFlattenCache: cache,
        updatedViewport: viewport
    )
}
```

## How the host uses it

The `onEvent` closure shrinks to:

```swift
onEvent: { slate, event in
    switch event {
    case .resize:
        slate.refreshWindowSize()
        
    case .external:
        break
        
    case .stdinBytes(let chunk):
        // ... input dispatch (same as today, but returns early if stop) ...
        
        // Drain events (mutates transcript state)
        drainIncomingEvents()
        
        // Auto-flush (mutates submit state)
        submitCoordinator.setModelBusy(modelBusy)
        let flushEffect = submitCoordinator.handleModelTurnEnd()
        if case .sendToGate(let text) = flushEffect { ... }
        
        // Build frame (pure)
        let state = RenderState(
            inputBuffer: inputHandler.buffer,
            modelBusy: modelBusy,
            queuedTrayText: queuedTrayText,
            banner: banner,
            usage: usageHUD,
            completedTranscript: transcriptController.completedLines,
            streamingOpenLine: transcriptController.streamingOpenLine,
            transcriptGeneration: transcriptController.generation,
            flattenCache: flattenCache,
            llmWaitAnimationFrame: llmWaitAnimationFrame,
            viewport: viewport,
            terminalCols: slate.cols,
            terminalRows: slate.rows
        )
        let output = buildFrame(state: state, theme: .default)
        
        // Apply state updates
        flattenCache = output.updatedFlattenCache
        viewport = output.updatedViewport
        
        // Write frame to Slate grid (side-effect, kept thin)
        slate.with { grid in
            for (row, line) in output.grid.enumerated() {
                for (col, span) in line.enumerated() {
                    grid[row, col] = TerminalCell(span: span)
                }
            }
        }
        
        return coordinatorFinished ? .stop : .continue
    }
}
```

## Testability

`buildFrame` is pure — no async, no Slate, no `@MainActor`. Tests look like:

```swift
@Test func frameIncludesBannerWhenPresent() {
    var state = RenderState.default
    state.banner = BannerSnapshot(
        baseURL: "http://localhost:8080",
        model: "test-model",
        cwd: "/tmp",
        scribeVersion: "abc123",
        gitBranch: "main",
        sessionId: "test-session"
    )
    let output = buildFrame(state: state, theme: .default)
    // Banner occupies row 0 — check it exists
    #expect(output.grid[0].contains(where: { $0.text.contains("test-model") }))
}

@Test func frameShowsQueuedTrayWhenMessageQueued() {
    var state = RenderState.default
    state.modelBusy = true
    state.queuedTrayText = "queued message"
    state.inputBuffer = ""
    let output = buildFrame(state: state, theme: .default)
    // Last content row should contain the queued tray text
    let lastContentRow = output.grid[output.grid.count - 2]
    #expect(lastContentRow.contains(where: { $0.text.contains("queued message") }))
}
```

## Benefits

1. **Render logic is testable** — every pixel placement can be asserted without a terminal.
2. **Slate-specific code is a 10-line shim** — `TerminalCell(span:)` mapping is trivial.
3. **RenderInputs is a snapshot** — the host captures state at the start of a frame and renders against a consistent snapshot; no risk of state changing mid-frame.
4. **Performance profiling is easier** — `buildFrame` can be benchmarked in isolation without the TTY throttler.

## Source changes

| File | Change |
|---|---|
| **New:** `ScribeCLI/SlateChat/RenderLoop.swift` | `buildFrame`, `RenderState`, `RenderOutput` |
| **Modify:** `SlateChatHost.swift` | Replace inline render logic with `buildFrame(state:)` call |
| **Modify:** `SlateChatRenderer.swift` | Split `render(into:...)` into `buildGrid(...)` (pure) + grid-writing shim |
| **New:** `Tests/ScribeCLITests/RenderLoopTests.swift` | Frame-level tests |
