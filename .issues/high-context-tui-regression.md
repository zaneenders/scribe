# High Context Length TUI Rendering Regression & Resume Metrics Bug

**Session ID:** `A27E19B2-A772-4663-949B-5C2B1C68936D`  
**Model:** `deepseek-v4-pro`  
**Messages in session:** 434 (2.1 MB on disk)  
**Date observed:** 2026-05-05

---

## Bug 1: TUI stops displaying scrolled output at very high context length

### Observed behavior

When the conversation grows to a high context length (400+ messages, ~2 MB of JSONL), the TUI rendering degrades significantly. Streaming output appears to freeze, scroll interactions become unresponsive, and the display may stop updating entirely during assistant generation. The problem is most pronounced during live streaming while the user is scrolled up (not following the live tail).

### Root cause: compounding rendering inefficiencies in the hot path

The render pipeline has several algorithmic inefficiencies that compound at scale. The hot path is `SlateChatHost.onEvent` → `syncFlattenedTranscript` → `makeGrid`, which runs on every render frame (~60 fps throttle).

#### 1. O(n²) markdown re-rendering during streaming

**File:** `Sources/ScribeCLI/SlateChat/SlateChatLayout.swift` — `appendAssistantText` handler

```swift
case .appendAssistantText(let section, let text):
    ...
    sink.assistantOpenLineRaw += text
    let rendered = self.markdownRenderer.render(
        text: sink.assistantOpenLineRaw,  // FULL accumulated text on every SSE chunk
        baseFG: st.fg,
        baseBold: st.bold,
        theme: section == .reasoning ? .grayscale : self.theme.markdown
    )
```

On every SSE chunk (70–2800+ chunks per turn in the observed session), `SwiftMarkdownRenderer.render` calls `Document(parsing: text)` on the **entire** accumulated text. The `styleRemainingMarkdown` pass then scans all spans with repeated `.range(of:)` operations:

**File:** `Sources/ScribeCLI/Markdown/SwiftMarkdownRenderer.swift` — `splitMarkdownPatterns`

```swift
while !remaining.isEmpty {
    let doubleIdx = remaining.range(of: "**")
    let singleIdx = remaining.range(of: "*")
    let backtickIdx = remaining.range(of: "`")
    ...
}
```

For a 5,000-character assistant response streaming in 200+ chunks, the markdown document is fully parsed and scanned ~200 times. The total cost is O(n²) in the response length.

#### 2. Flatten cache invalidated on every SSE chunk

**File:** `Sources/ScribeCLI/SlateChat/SlateChatLayout.swift` — `appendAssistantText` handler

```swift
if removeCount > 0 {
    sink.lines.removeLast(removeCount)
    sink.lineGeneration += 1   // ← bumps on EVERY chunk during streaming
}
```

**File:** `Sources/ScribeCLI/SlateChat/SlateChatHost.swift` — `syncFlattenedTranscript`

```swift
if width != flattenCache.wrapWidth || generation != flattenCache.lastGeneration {
    flattenCache = TranscriptFlattenCache()
    ...
    flattenCache.completedFlat = TranscriptLayout.flattenedRows(from: completed, width: width)
```

A `lineGeneration` bump invalidates the entire flatten cache, forcing a full word-wrap pass of all ~4,000 logical lines on every single SSE chunk. `TranscriptLayout.flattenedRows` is O(total characters across all lines), rebuilding span-to-character mappings and re-wrapping each logical line. With shell outputs and file contents in the scrollback, this can process tens of thousands of characters per frame.

#### 3. `removeFirst` O(n) shift in trim

**File:** `Sources/ScribeCLI/SlateChat/SlateChatLayout.swift`

```swift
private func trimIfNeeded(_ lines: inout [TLine]) {
    let cap = 4_000
    if lines.count > cap {
        lines.removeFirst(lines.count - cap)  // O(n) — shifts all remaining elements
    }
}
```

`Array.removeFirst(k)` shifts all remaining elements down. Called from `enterAssistantSection`, `recordUserSubmission`, `appendLine`, and `appendAssistantText`, this O(n) shift happens frequently on a near-capacity array.

#### 4. Synchronous full-history replay blocks first render

**File:** `Sources/ScribeCLI/SlateChat/SlateChatHost.swift` — `run()` prepare closure

```swift
if let resumed = resumeSnapshot {
    TranscriptReplay.replay(
        messages: resumed.messages,   // 432 messages, 2.1 MB
        onEvent: { sink.emit($0) },
        recordUserSubmission: { sink.recordUserSubmission(trimmedVisible: $0) }
    )
    self.flattenCache = TranscriptFlattenCache()
}
```

The entire conversation history is replayed synchronously inside the `prepare` closure, blocking the main actor. For large sessions, this means hundreds of markdown renders, tool output formattings, and transcript line appends happen before the first render frame reaches the screen. The user sees a blank terminal until replay completes.

#### 5. Open-line flatten on every frame even while scrolled up

**File:** `Sources/ScribeCLI/SlateChat/SlateChatHost.swift` — `syncFlattenedTranscript`

```swift
if let open {
    return flattenCache.completedFlat
        + TranscriptLayout.flattenedRows(from: [open], width: width)
}
```

Even when the user has scrolled up (not following the live tail), every render frame re-wraps the open line. Combined with the markdown re-render and potential full-flatten-cache rebuild, each frame can exceed the ~16ms budget at 60 fps, causing dropped frames and apparent freezes.

### Suggested fixes

| Issue | Fix |
|---|---|
| O(n²) markdown | Debounce markdown renders — re-render on a timer (~50ms) or every N chunks, not every chunk. Consider an incremental markdown parser. |
| `lineGeneration` thrash | Don't bump `lineGeneration` on intra-section replacement. Use a separate mechanism (e.g., a dirty flag scoped to the open line) that only invalidates the open-line portion of the cache, not the full `completedFlat`. |
| `removeFirst` cost | Replace the `[TLine]` array with a ring buffer or `Deque` (swift-collections), or use `ArraySlice` indices instead of mutating the array front. |
| Synchronous replay | Replay in chunks with `Task.yield()` between messages, or replay into a background buffer and swap it in atomically so the first render frame appears quickly. |
| Scrolled-up flatten | Skip the open-line re-wrap when `followingLiveTranscript` is `false` — the user can't see the open line anyway. Or cache the open line's previous flatten width and only recompute if the text actually changed. |

---

### Deeper fix exploration: visual-row windowing

The core insight is that the TUI only needs to render lines that are **on screen plus a small scroll buffer** (~5 rows above and below). Everything else is wasted work. The current pipeline renders the entire document on every frame; a windowed pipeline would render only ~50 visual rows regardless of how large the transcript grows.

#### The windowing model

```
Terminal: 40 rows tall, scroll offset at visual row 200

Before (current):                       After (windowed):
  render all ~4000 logical lines           compute which logical lines produce
  → word-wrap all of them                  visual rows 195–245 (window ± 5 buffer)
  → produce ~6000 visual rows              → markdown-render only those logical lines
  → slice [200..<240] for display          → word-wrap only those ~50 rows
  → discard the other 5960 rows            → blit to grid

Cost: O(full transcript)                  Cost: O(viewport), constant
```

The 5-row buffer on each side means scrolling by a few lines is free — just adjust the viewport offset. When the user scrolls past the buffer edge, re-center the window and re-render.

#### The mapping problem

To know which logical lines correspond to visual rows 195–245, you need to know how many visual rows each logical line consumes after word-wrapping. A logical line of 200 characters at width 80 produces ceil(200/80) = 3 visual rows. A code block with 20 lines produces exactly 20 visual rows (no wrapping for code).

**Solution: maintain a visual-row index alongside the logical-line buffer**

```swift
/// Maps logical line index → starting visual row.
/// visualRowOfLogicalLine[i] is the visual row where logical line i begins.
/// Built incrementally as lines are appended; O(1) per append.
private var visualRowOfLogicalLine: [Int] = [0]

func appendLogicalLine(_ line: TLine, width: Int) {
    logicalLines.append(line)
    let prevStart = visualRowOfLogicalLine.last!
    let visualHeight = visualRowsConsumed(by: line, width: width)
    visualRowOfLogicalLine.append(prevStart + visualHeight)
}

/// Inverse: given a visual row, find the logical line that contains it.
/// Binary search on visualRowOfLogicalLine → O(log n).
func logicalLineIndex(forVisualRow row: Int) -> Int {
    var lo = 0, hi = visualRowOfLogicalLine.count - 1
    while lo < hi {
        let mid = (lo + hi + 1) / 2
        if visualRowOfLogicalLine[mid] <= row { lo = mid }
        else { hi = mid - 1 }
    }
    return lo
}
```

With this index, a render frame at scroll offset S with terminal height H becomes:

```
let windowStart = max(0, S - 5)           // visual row, with buffer above
let windowEnd = min(totalVisualRows, S + H + 5)
let firstLogical = logicalLineIndex(forVisualRow: windowStart)
let lastLogical = logicalLineIndex(forVisualRow: windowEnd)

// Only flatten logical lines [firstLogical...lastLogical]
let visible = TranscriptLayout.flattenedRows(
    from: Array(logicalLines[firstLogical...lastLogical]),
    width: width
)

// Trim to exact viewport
let offset = windowStart - visualRowOfLogicalLine[firstLogical]
let slice = visible.dropFirst(offset).prefix(H)
```

#### Why a rope is still useful (for the streaming open line)

The windowing above handles completed scrollback. The streaming assistant text (the "open line") has a separate problem: the raw text accumulates as a `String`, and every chunk triggers `sink.assistantOpenLineRaw += text` (a full O(n) String copy). A `Rope` from `swift-collections` makes append O(log n):

```swift
private var assistantText: Rope = Rope()

func appendChunk(_ text: String) {
    assistantText.append(contentsOf: text)  // O(log n), no copy
}
```

The markdown parser (`Document(parsing:)`) wants a `String`, so we materialize once per windowed render, not once per chunk. Combined with debouncing (only re-render on a timer, not every chunk), the parsing cost drops from O(chunks × docLength) to O(docLength) — and the windowing means we only pay for the visible portion of that.

#### Putting it together: the full windowed pipeline

```
SSE chunk arrives
  → append to Rope (O(log n))
  → set dirty flag

Render timer fires (~30fps) OR stream ends:
  → if not dirty, skip
  → compute visual-row window [scrollOffset - 5, scrollOffset + rows + 5]
  → materialize window substring from Rope for the open line (if streaming)
  → markdown-render ONLY the logical lines in the window
  → word-wrap only those ~50 visual rows
  → blit to grid
  → clear dirty flag

User scrolls:
  → shift viewport offset
  → if still within buffer bounds: no re-render needed (just re-blit existing grid)
  → if crossing buffer boundary: recenter window, set dirty flag
```

This decouples rendering cost from transcript size entirely. A session with 10 messages or 10,000 messages costs the same per frame — O(viewport) instead of O(transcript).

#### Compared to the simpler debounce-only fix

Debouncing alone (Approach C from the AST section) would reduce parse count from 200 to ~10 per turn, which already changes O(n²) → O(n). Adding the visual-row window on top makes it O(viewport), which is the asymptotically correct solution. The debounce can ship first as a low-risk immediate improvement; the windowed pipeline is the longer-term fix.

---

## Bug 2: Usage metrics reset to zero on resume

### Observed behavior

After resuming a session (`scribe chat --resume ...`), the HUD in the upper-right of the TUI shows:

```
in 0  ·  out 0  ·  ctx —%
turn Σ 0  ·  all Σ 0
```

All historical token usage from the previous session is lost. Only tokens consumed after resume are counted. The `all Σ` (session total) counter starts from 0 instead of reflecting the cumulative total across both the original and resumed portions of the session.

### Root cause: usage data is never persisted

#### How metrics accumulate during a live session

1. Each API round ends with `AgentHarness.finalizeTurn` emitting `.usage(usage, tokensPerSecond:)`
2. `SlateTranscriptSink.emit` receives `.usage` and accumulates:

**File:** `Sources/ScribeCLI/SlateChat/SlateChatLayout.swift` — `.usage` handler

```swift
case .usage(let usage, let tps):
    guard let triple = usage.scribeReportedPromptCompletionTotal else { break }
    state.withLock { sink in
        sink.usageTurnPrompt += triple.prompt       // reset per user turn
        sink.usageTurnCompletion += triple.completion
        sink.usageTurnTotal += triple.total
        sink.usageSessionPrompt += triple.prompt    // never reset — session lifetime
        sink.usageSessionCompletion += triple.completion
        sink.usageSessionTotal += triple.total
        ...
    }
```

3. Turn counters reset on `.modelTurnRunning(true)`:

```swift
case .modelTurnRunning(let running):
    if running {
        sink.usageTurnPrompt = 0
        sink.usageTurnCompletion = 0
        sink.usageTurnTotal = 0
    }
```

4. `ChatSessionArchive` is persisted periodically, but only stores `messages: [ChatMessage]`:

**File:** `Sources/ScribeCore/ChatSessionPersistence.swift` — `ChatSessionArchive`

```swift
public struct ChatSessionArchive: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var id: UUID
    public var createdAt: Date
    public var updatedAt: Date
    public var cwd: String
    public var model: String
    public var baseURL: String?
    public var messages: [Components.Schemas.ChatMessage]  // ← only messages, no usage
}
```

`CompletionUsage` (prompt tokens, completion tokens, reasoning tokens, cached tokens, etc.) comes from SSE stream chunks and is **never persisted** to the archive.

#### What happens on resume

1. `SlateChatHost.run` loads `ChatSessionArchive` and calls `TranscriptReplay.replay` to rebuild scrollback
2. `TranscriptReplay.replay` **only** emits display events:

**File:** `Sources/ScribeCore/TranscriptReplay.swift`

```swift
// Events emitted during replay:
.onEvent(.enterAssistantSection(...))
.onEvent(.appendAssistantText(...))
.onEvent(.finalizeAssistantStream)
.onEvent(.toolRoundHeader(...))
.onEvent(.toolInvocation(...))
.onEvent(.blankLine)
// Events NOT emitted:
//   .usage(...)              ← usage data not available in messages
//   .modelTurnRunning(...)   ← turn boundaries not tracked
```

3. The `SlateTranscriptSink` starts with all usage counters (`usageSessionPrompt`, etc.) at **zero**
4. The `TokenTracker` in `ScribeAgent` is also created fresh, with `sessionTotalTokens = 0`

**Result:** The session-level HUD metrics (`all Σ`) show only tokens consumed since resume, not the full session history. In the observed session, ~500K tokens of historical usage were invisible after resume.

### Suggested fix

1. **Persist usage per message.** Annotate assistant messages in the archive with their `CompletionUsage` (tokens, reasoning tokens, cached tokens). Options:
   - Add an optional `usage` field to the JSONL message encoding (custom wrapper or sidecar)
   - Write a separate `usage.jsonl` alongside `messages.jsonl` with one usage entry per assistant turn

2. **Emit `.usage` during replay.** Have `TranscriptReplay` emit `.usage` events when usage data is available, so the sink can rebuild its counters.

3. **Emit `.modelTurnRunning` boundaries during replay.** Track user→assistant transitions and emit `.modelTurnRunning(true)`/`.modelTurnRunning(false)` pairs so turn-level counters are properly bounded.

4. **Store cumulative session totals in metadata.** Add `sessionPromptTokens` and `sessionCompletionTokens` fields to `ChatSessionMetadata`/`ChatSessionArchive`, updated on each persist. On resume, pre-seed the sink's session counters from the archive metadata so the HUD is immediately correct.

---

## Artifacts

- Log file: `scribe-A27E19B2-A772-4663-949B-5C2B1C68936D.log` (1,824 lines)
- Messages file: `messages.jsonl` (434 messages, 2,133,347 bytes)
- Metadata: `metadata.json`
