# Rendering Performance Fix Plan

## Problem

During LLM streaming (model producing SSE chunks at ~32/s), the chat renderer
burns ~77 ms per frame just in layout (`prepare_ms`).  The log fires
`chat.render.slow` every ~80 ms at ~1100 flat rows, and the main actor is
fully saturated.  Even with the 60 fps coalescing throttle, **every frame that
reaches the screen re-does O(full‑transcript) work**.

Three root causes feed each other:

### 1. Flatten cache thrown away on every SSE chunk (`SlateChatHost.swift`)
`appendAssistantText` increments `lineGeneration` every chunk, so
`syncFlattenedTranscript` always hits the *“generation changed → full rebuild”*
path.  The cache is never used incrementally during a stream.

### 2. Full markdown re‑parse on every SSE chunk (`SlateChatLayout.swift`)
`SwiftMarkdownRenderer.render(text:)` receives the **entire** accumulated
`assistantOpenLineRaw` string and calls `Document(parsing:)` from scratch.
Parse cost grows with response length – O(n²) when combined with chunk count.

### 3. Spinner adds extra renders while the model is busy (`SlateChatHost.swift`)
A `Task` fires `requestRender()` every 90 ms to animate the spinner.  SSE
chunks already drive renders; the spinner task just adds 11 fps of redundant
layout work on top.

---

## Proposed changes (in dependency order)

### Step A – Make the flatten cache survive streaming updates

**File:** `Sources/ScribeCLI/SlateChat/SlateChatHost.swift`
**Function:** `syncFlattenedTranscript`

Instead of comparing `generation` (which changes every chunk), compare
`completed.count` only, and handle the *“lines were replaced from the middle”*
case explicitly.

Right now:
```swift
if width != flattenCache.wrapWidth || generation != flattenCache.lastGeneration {
    // FULL REBUILD — hit every chunk because generation always changes
    flattenCache = TranscriptFlattenCache()
    ...
} else if completed.count < flattenCache.completedLogicalLines {
    // lines removed from end (e.g. trim)
    ...
} else if completed.count > flattenCache.completedLogicalLines {
    // lines appended at end (incremental)
    ...
}
```

**Fix:** Remove the `generation` check.  Replace it with a comparison of
`completed.count` vs `flattenCache.completedLogicalLines`.  When
`completed.count == flattenCache.completedLogicalLines` and the width hasn't
changed, return the cached `completedFlat` immediately (zero work).  For the
mid-array replacement case (which only happens during streaming), add a third
branch: detect that the count is the same but `lineGeneration` changed, and
re‑flatten only the suffix from `assistantSectionStartIndex` onward (expose
that index on the sink snapshot).

| Before | After |
|---|---|
| ~77 ms every SSE chunk | ~0 ms (cache hit) for completed prefix + small cost for the open tail |

### Step B – Avoid full markdown re‑parse on each token

**File:** `Sources/ScribeCLI/SlateChat/SlateChatLayout.swift`
**Handler:** `.appendAssistantText`

Today `assistantOpenLineRaw` accumulates every token and feeds the whole
string to `Document(parsing:)`.  Paraphrasing the hot path:

```swift
sink.assistantOpenLineRaw += text            // append one token
let rendered = self.markdownRenderer.render(
    text: sink.assistantOpenLineRaw,         // parse ALL of it again
    ...
)
```

**Fix – throttle re‑renders to ~15 fps (every ~66 ms):** record the wall time
of the last markdown render.  If the SSE chunk arrives sooner than the
threshold, append the raw token to `assistantOpenLineRaw` but **skip** the
`render()` + splice step for this chunk.  The next chunk that falls after the
threshold does a single catch‑up render of the whole text.  This reduces
markdown renders from 32/s to ~15/s with no visual difference (terminal
refresh is bottlenecked by the 60 fps coalescer anyway).

Additionally, clamp the re‑parse to the **last N lines** of the accumulated
text when the total exceeds ~200 lines.  Streamed markdown past the viewport
height cannot be seen; re‑parsing invisible prefix is pure overhead.

**Alternative deeper fix:** make the markdown renderer incremental (append
token → walk only newly‑affected AST nodes).  This is substantially more work
and is *not* recommended as a first pass.  The throttle + clamp approach above
should drop render cost by >80%.

### Step C – Remove redundant spinner‑only renders

**File:** `Sources/ScribeCLI/SlateChat/SlateChatHost.swift`
**Location:** `spinnerTask` inside `run()`

The current spinner writes `requestRender()` every 90 ms unconditionally while
`modelTurnBusy` is true.  SSE chunks already wake the render pump; the spinner
wake is redundant during active streaming.  It's only needed when the model is
**waiting for the first token** (TTFB gap where no chunks arrive).

**Fix:** Guard the spinner render so it only fires when the *last external
wake* was more than 90 ms ago — i.e. only during silence.  Track the last
`ExternalWake` timestamp on the host and skip the spinner render if an SSE
chunk arrived in the last 90 ms.

Alternatively, just increase the interval to 120 ms; the braille spinner
looks fine at ~8 fps instead of 11 fps.

### Step D – (Optional) Skip flatten of invisible transcript prefix

**File:** `Sources/ScribeCLI/SlateChat/SlateChatHost.swift`
**Function:** `syncFlattenedTranscript`

When `followingLiveTranscript` is true, the viewport shows the last
`contentRows` lines.  Lines `0 ..< (count - contentRows)` are never painted.
Currently `flattenedRows` word‑wraps every logical line in the full transcript
(up to 4,000 logical lines).  We can exploit the trim cap:

- Hold `completedFlat` at a maximum of `contentRows * 3` entries by dropping
  from the front after appending.  The scroll‑back path already handles
  `transcriptFirstVisibleRow` clamping, so old rows are not recoverable anyway
  once they exceed the 4,000‑line cap.

This is a smaller win (flatten cost is proportional to **new** lines, not
existing flat rows in the incremental path), but it bounds memory for very
long sessions.

---

## Expected impact

| Change | Before | After |
|---|---|---|
| Cache rebuild frequency | Every SSE chunk (32/s) | Only on logical‑line addition (rare during stream) |
| Markdown parse frequency | Every SSE chunk (32/s) | ~15/s (throttle) or ~1/s (viewport‑clamped) |
| Spinner renders during stream | +11/s | 0/s |
| **Main‑actor render CPU** | ~2,500 ms/s (oversubscribed) | ~100–200 ms/s (ample headroom) |

The `chat.render.slow` log line should disappear (or at least drop to
`prepare_ms < 10`).

## Implementation order

1. **Step A** first — it's the biggest win for the smallest code change
   (~15 lines touched) and directly addresses the 77 ms `prepare_ms`.

2. **Step B** second — markdown throttle; a simple timestamp guard in
   `appendAssistantText`.

3. **Step C** third — spinner guard; a one‑line condition.

4. **Step D** is polish; schedule when convenient.

## Verification

Scribe ships with an [in-process sampling profiler](https://github.com/apple/swift-profile-recorder)
(see [DEVELOPMENT.md](./DEVELOPMENT.md#profiling) for setup). Use it to
confirm the fix — before and after profiles tell the story far better than
log scraping.

### Before‑fix baseline

1. Launch scribe with the profiler enabled:
   ```bash
   PROFILE_RECORDER_SERVER_URL_PATTERN='unix:///tmp/scribe-{PID}.sock' \
     swift run scribe chat
   ```
2. Start a streaming model request (a long code-gen prompt works well).
3. While the model streams, capture a profile from another terminal:
   ```bash
   curl --unix-socket /tmp/scribe-$(ls /tmp/scribe-*.sock | head -1 | sed 's/.*scribe-//;s/\.sock//').sock \
     -sd '{"numberOfSamples":500,"timeInterval":"10ms"}' \
     http://localhost/sample > ./before.perf
   ```
4. Drag `before.perf` onto [speedscope.app](https://speedscope.app).

**Expected before picture:** `speedscope` shows the main actor saturated in
`syncFlattenedTranscript` → `Document(parsing:)` → `requestRender()` — a
wide band of the same call stack at ~100 Hz, aligning with the ~77 ms
`prepare_ms` logged by `chat.render.slow`.

### After‑fix verification (repeat after each Step)

1. Rebuild, relaunch with the same profiler env var, re-run the same prompt.
2. Capture a matching profile:
   ```bash
   curl --unix-socket … > ./after-step-A.perf
   ```
3. Compare in speedscope:
   - **After Step A:** The `syncFlattenedTranscript` band should collapse to
     narrow spikes (only when a new logical line is emitted). Main-actor
     saturation should drop from ~100% to well under 30%.
   - **After Step B:** `Document(parsing:)` should shrink to ~15 Hz or less.
     Combined with Step A, main-actor CPU should be ~10–15%.
   - **After Step C:** The idle-thread samples from the spinner task (GCD
     timer firing every 90 ms → `requestRender`) should disappear from the
     trace — no `requestRender` calls without an SSE chunk preceding them.

### Coarse health signals (still useful)

- `tail -f ~/.local/share/scribe/logs/scribe-*.log | grep render.slow` —
  should fire rarely or not at all post‑fix.
- `top` / `ps` — scribe CPU should drop from 60%+ to < 10% during streaming.
- The `chat.render.slow` log line itself records `prepare_ms`; if it still
  fires, inspect the value to gauge remaining work.
