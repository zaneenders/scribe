# Extract a `TranscriptController` — the transcript state machine

## Problem

`SlateChatHost.handleTranscriptEvent` (~250 lines, lines ~480–730) is a single
`switch` over `TranscriptEvent` that mutates host state directly:

- `transcriptLines` (completed lines)
- `streamingOpenLine` (currently-streaming open line)
- `streamingOpenLineRaw` (accumulated raw text for finalize)
- `streamingSectionStartLineIndex` (for inline replacement during stream)
- `currentStreamingSection` (.answer / .reasoning)
- `transcriptGeneration` (cache invalidation)

This logic is a pure state machine — it takes current state + an event and
produces new state. It has no business being inside a `@MainActor` Slate host
alongside render calls, input handling, and TUI lifecycle management.

## What to extract

```swift
/// Owns the transcript line buffer and streaming state.
/// Pure value type — Sendable, no MainActor, no Slate dependency.
struct TranscriptController: Sendable {
    /// Completed transcript lines (user messages, finalized assistant turns,
    /// tool output).
    private(set) var completedLines: [TLine] = []

    /// Open line being built during streaming (nil when idle).
    private(set) var streamingOpenLine: TLine? = nil

    /// Accumulated raw text of the current streaming section (for finalize).
    private(set) var streamingRawText: String = ""

    /// Index into `completedLines` where the current streaming section started.
    /// Used to replace the streaming tail on each chunk.
    private(set) var streamingSectionStartLineIndex: Int? = nil

    /// Which section is currently streaming (.answer / .reasoning).
    private(set) var currentStreamingSection: AssistantStreamSection = .answer

    /// Bumped when transcript structure changes (for FlattenCache invalidation).
    private(set) var generation: Int = 0

    // MARK: - Event application

    /// Apply a TranscriptEvent, mutating state and returning whether a render
    /// is needed.  The `theme` and `renderer` are injected so this stays pure
    /// (no global dependencies).
    mutating func apply(
        _ event: TranscriptEvent,
        theme: CLITheme,
        renderer: MarkdownRenderer
    ) -> ApplyResult

    // MARK: - Queries

    /// True if the last completed line (if any) is a user-submission line.
    func isLastLineUserSubmission() -> Bool
}

struct ApplyResult {
    /// Whether the caller should request a render frame.
    var needsRender: Bool
    /// If non-nil, the streaming render produced a drift from the batch
    /// render (logged as a warning by the host).
    var driftDetail: String? = nil
}
```

## What each event arm does (current behavior mapped to new type)

| Event | Current behavior | `TranscriptController` equivalent |
|---|---|---|
| `.enterAssistantSection` | Finalizes open line, appends section header lines, resets streaming state | Same — mutates `completedLines`, resets streaming fields |
| `.appendAssistantText` | Tail-renders markdown, replaces streaming section in `transcriptLines` | Same — takes `theme` + `renderer` as parameters |
| `.finalizeAssistantStream` | Full block-level markdown render, finalizes streaming section | Same |
| `.emptyAssistantTurn` | Appends "(empty turn)" line | Same |
| `.usage` | **Does NOT touch transcript** — just returns `needsRender: false` (usage handled separately by host) | `needsRender: false` |
| `.blankLine` | Appends empty `TLine` | Same |
| `.toolRoundHeader` | Appends header line | Same |
| `.toolInvocation` | Appends tool invocation + output lines | Same |
| `.skippedUnreadableStreamLine` | Appends warning line | Same |
| `.harnessError` | Appends error line | Same |
| `.turnInterrupted` | Appends "(interrupted)" line, resets streaming state | Same |
| `.userSubmitted` | Appends user prefix + message lines | Same |
| `.turnComplete` | Finalizes streaming, compares streaming vs batch render | `driftDetail` returned for logging |

## Benefits

1. **Immediately testable** — pump in `TranscriptEvent` sequences and assert on
   `completedLines` + `streamingOpenLine` without any TUI infrastructure.

   ```swift
   @Test func assistantTextStreamingProducesCorrectLines() {
       var c = TranscriptController()
       _ = c.apply(.enterAssistantSection(.answer, nil), theme: .default, renderer: renderer)
       let result = c.apply(.appendAssistantText(.answer, "hello world"), theme: .default, renderer: renderer)
       #expect(result.needsRender)
       #expect(c.streamingOpenLine != nil)
       #expect(c.streamingRawText == "hello world")
   }
   ```

2. **Isolates drift detection** — the `turnComplete` drift comparison currently
   lives inside the host; extracting it to `TranscriptController` makes it
   testable (and the drift-detection log output can become a structured return
   value instead of a side-effect).

3. **Reduces `SlateChatHost` by ~250 lines** — the `handleTranscriptEvent`
   switch becomes a thin call-through:

   ```swift
   private func handleTranscriptEvent(_ event: TranscriptEvent) {
       let result = transcriptController.apply(event, theme: theme, renderer: markdownRenderer)
       if result.needsRender { renderWake?.requestRender() }
       if let drift = result.driftDetail { log.warning("transcript.streaming-drift", metadata: ["detail": .string(drift)]) }
   }
   ```

4. **Matches existing patterns** — `SubmitCoordinator` and `TranscriptViewport`
   are already pure state machines extracted from the host. This follows the
   same pattern exactly.

## Source changes

| File | Change |
|---|---|
| **New:** `ScribeCLI/SlateChat/TranscriptController.swift` | New type |
| **Modify:** `SlateChatHost.swift` | Replace `handleTranscriptEvent` switch body with `transcriptController.apply(...)`; remove now-dead fields |
| **New:** `Tests/ScribeCLITests/TranscriptControllerTests.swift` | Event-by-event tests + integrated turn tests |
