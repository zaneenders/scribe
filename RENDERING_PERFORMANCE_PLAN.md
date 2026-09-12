# Rendering Performance Investigation and Improvement Plan

## Findings

A live sample of the slow release-build backend (PID `88317` at capture time) showed approximately 77% of main-thread samples inside `RemoteServer.render → BlockEngine.draw`, including stack traversal, layout, and measurement.

The logs show two distinct issues:

| Issue | Evidence |
| --- | --- |
| Expensive server frames | Draw times typically 33–71 ms, rising to 109–328 ms |
| Additional stalls outside measured drawing | Requests taking 1.5–8.8 seconds despite much shorter reported draw times |

Client decode (~0.04 ms), CPU encode (~0.2 ms), and GPU rendering (usually ~5 ms) are not the dominant measured costs. Low bandwidth is consistent with too few frames being produced; it does not establish a network bottleneck.

The server culls draw commands after traversing/drawing the UI tree. A small transmitted command count therefore does not imply little layout work.

At inspection time, another Scribe backend and a parallel Swift test build were also consuming CPU. This contention may worsen latency, but does not establish the root cause.

The initial sample is saved at `/tmp/scribe-slow-backend.sample`. The short sample does not establish the cause of the multi-second stalls.

## Required Architecture: Visible UI Only

This is the first requirement, ahead of optimizing layout caches:

- Only visible session panes participate in UI graph construction, layout, drawing, and hit testing. Hidden sessions must not build or traverse transcript UI graphs.
- Within a visible transcript, construct and render only viewport-visible rows plus a small, bounded overscan buffer. Do not construct every row and discard its draw commands afterward.
- Background sessions may continue agent execution, ingest events, and persist canonical conversation state. That work is separate from parsing/formatting content for presentation and constructing a UI graph.
- Defer presentation-only parsing, formatting, and graph construction for hidden sessions until needed for visibility. Update lightweight sidebar metadata (title, running state, unread indicator) independently of transcript presentation.
- Background transcript changes must not invalidate or rebuild the visible transcript. They may update visible sidebar indicators when those indicators actually change.
- On session activation, materialize the visible portion from the latest canonical state; avoid replaying every intermediate UI update. Preserve scroll position and use cached heights or estimates for offscreen rows.
- If multiple panes are visible, apply these rules to each visible pane rather than assuming exactly one active session.

### Acceptance Criteria

- Increasing the number or history length of hidden sessions does not increase visible transcript graph construction, layout, or draw work.
- Streaming into a hidden session produces no transcript UI graph work for that session, while execution, persistence, and visible status indicators remain correct.
- Increasing offscreen transcript history does not cause a full row-graph traversal on every frame.
- Switching sessions shows current state correctly without requiring eager presentation work for every open session.

These are requirements to verify with instrumentation, not a claim that the current implementation renders every session. The initial profile established expensive tree traversal, not which sessions contributed to it.

## Improvements, in Priority Order

Implement and verify visible-only presentation first, then optimize the remaining visible work below.

### 1. Avoid repeated layout and measurement

Profile the measurement and layout paths in `BlockEngine`, stacks, and transcript content. Cache results using content revision, available width, and relevant style inputs. Reuse them until those inputs change.

Ensure cache invalidation handles text updates, resizing, font/style changes, and other layout dependencies correctly.

### 2. Virtualize the transcript

Culling drawing commands after traversal saves transport/GPU work, but not the preceding UI work.

Lay out and draw visible rows plus a small buffer. Retain cached heights for offscreen rows, preserving scroll position when estimates or content heights change.

### 3. Coalesce streaming UI updates

Determine whether token/tool events repeatedly invalidate the UI. If so, publish presentation updates at a bounded cadence instead of per event.

Preserve every event in the underlying state, maintain ordering, and flush immediately on completion. The initial sample does not establish how much this contributes, so measure before changing it.

### 4. Instrument the gaps between frames

Record timestamps for:

1. Request arrival.
2. Main-thread request handling.
3. Draw start and end.
4. Encoding start and end.
5. Write completion.

Correlate these with frame/request identifiers and capture unchanged-frame responses as well as changed frames. A two-second request with a 24-ms draw cannot be explained by layout alone. Investigate scheduling, backpressure, and other main-thread work without assuming which is responsible.

### Not the first priority

Do not prioritize GPU batching or wire compression until profiling shows they are significant costs.

## Profiling Procedure

### Launch the slow instance with profiling enabled

Keep the build in release mode. Save active work before replacing the running instance.

From `/Users/zane/Developer/scribe`:

```bash
PROFILE_RECORDER_SERVER_URL_PATTERN='unix:///tmp/scribe-{PID}.sock' \
  .build/release/scribe-mac
```

This launches the existing release binary without starting another compilation. The `{PID}` placeholder is expanded by the profile recorder.

### Select the backend, not just the frontend

Find the new `scribe-mac --backend` process and its matching socket. Do not reuse the old PID or arbitrarily select the first socket when multiple instances are running.

```bash
ps -axo pid,ppid,command | grep '[s]cribe-mac'
ls /tmp/scribe-*.sock
```

### Capture while reproducing the slowdown

Replace `BACKEND_PID` with the actual backend PID:

```bash
curl --unix-socket /tmp/scribe-BACKEND_PID.sock \
  -sd '{"numberOfSamples":2000,"timeInterval":"10ms"}' \
  http://localhost/sample > /tmp/scribe-rendering-samples.perf
```

This requests approximately 20 seconds of samples at 10-ms intervals. Start with 500 samples (approximately five seconds) if a shorter capture is sufficient. Profiling adds overhead, so compare with unprofiled rendering statistics too.

The agent can identify the backend and trigger the capture once the instance is running; the user only needs to reproduce the slow interaction during capture.

### Capture separate scenarios

1. Idle with the affected transcript open.
2. Scrolling through that transcript.
3. Active response/tool-output streaming.

Reproduce each active scenario for 10–20 seconds. Ideally let the current Swift build finish before the first capture to establish a baseline without compiler contention. Note which other Scribe instances remain active.

Open the resulting `.perf` file in [Speedscope](https://www.speedscope.app/) or inspect it programmatically. The recorder captures all threads; distinguish idle/waiting threads from the backend main-thread hot paths.

## Validation and Coordination

- Compare the same transcript, viewport, and interaction before and after changes.
- Track server draw time, request latency, received/rendered FPS, and idle CPU usage.
- Check scrolling stability, streaming ordering, resize behavior, and final-update delivery.
- Use a separate branch/worktree for implementation to avoid colliding with the other agent's active edits.
- Treat this document as an investigation plan, not a claim that the optimizations have been implemented or validated.
