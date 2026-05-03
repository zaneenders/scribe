# Chat input behavior

Reference for how the Slate chat host (`Sources/ScribeCLI/SlateChat.swift`) routes
user input — `Enter`, `Ctrl+C`, and the queued-tray strip — relative to the
agent's busy/idle state.

## Behavior table

| Situation | Result |
|---|---|
| Agent **idle** + Enter (non-empty buffer) | Message is sent **immediately** to the agent (no tray, no delay). Recorded in scrollback as orange `you:`. |
| Agent **busy** + Enter (non-empty buffer) | Buffer text goes into the **queued tray** above the input box (orange `queued:` label, light-gray text on the input strip background). Not in scrollback yet. |
| Agent busy + queue exists + Enter on **empty** buffer | **Interrupts** the in-flight turn and **sends** the queued message. Recorded in scrollback at the moment the coordinator picks it up. |
| Agent busy + queue exists + types more + Enter | New buffer text **replaces** the queued message in the tray (single-slot queue). |
| Queue exists + **Ctrl+C** (1st press) | Queued message is moved back into the **input box** for editing. **The agent keeps running.** |
| No queue + agent busy + **Ctrl+C** (2nd press of the ladder) | Interrupts the agent. |
| No queue + agent idle + **Ctrl+C** (3rd press of the ladder) | Exits the chat. |
| Agent finishes a turn **naturally** with queue non-empty | Queued message is **auto-flushed** to the coordinator on the busy → idle transition. |

### Ctrl+C ladder

When a queued message exists, three taps of Ctrl+C walk you through three
distinct states:

1. **Recall** — first press pulls the queued message back into the input box so
   you can edit it. The agent is unaffected and keeps streaming.
2. **Interrupt** — second press (queue now empty, agent still busy) interrupts
   the in-flight model turn.
3. **Exit** — third press (queue empty, agent idle) exits the chat.

If the agent is already idle when you start pressing, step 2 is skipped: a
single Ctrl+C with no queue exits.

## Notes

- **Single-slot queue.** Submitting again while busy replaces the previous queued
  message rather than appending; recall it with Ctrl+C if you want to edit
  instead of overwrite.
- **Scrollback recording is deferred to pickup.** `readUserLine` is wrapped so
  the orange `you:` block is appended to scrollback exactly when the coordinator
  consumes the line. This gives the right ordering for the interrupt-and-send
  case:
  `previous turn → (interrupted) → you: queued message → new response`.
- **Tray geometry.** The tray sits between the transcript and the input strip,
  shares the input strip background, indents continuation rows under an 8-space
  gutter (matching the width of `queued: `), and is hard-capped at 4 rows with
  trailing `…` truncation so a long queued paste cannot push the transcript off
  screen.
- **Busy → idle transition** is detected in the host's render callback by
  comparing `sink.modelTurnBusy()` against the previous render's snapshot
  (`lastObservedModelBusy`); the auto-flush fires exactly once per transition.
  `markModelTurnRunning(false)` also schedules a deferred 50 ms follow-up
  `requestRender()` so the throttled external-wake stream cannot drop the
  trailing render that paints the new idle state.

## Render pipeline & input responsiveness

Slate's renderer runs on `@MainActor` — the same actor that drains stdin events
through the wake pump's `onEvent`. Every render builds a cell grid, encodes it
into a single contiguous byte run, and submits it to the controlling tty.

To keep keystrokes responsive while the model is busy:

1. **Slate ships frames through an async writer.** `Slate.enscribe` builds the
   grid synchronously on the main actor, copies the encoded bytes into an
   owned `[UInt8]`, and submits them to a detached writer task that performs
   the actual blocking `write(2)` call(s). The main actor never waits on tty
   drain. See `Sources/SlateCore/AsyncFrameWriter.swift`.
2. **Frames coalesce on the writer side.** The writer's input stream uses
   `bufferingPolicy: .bufferingNewest(1)`: while a frame is being written, an
   incoming frame replaces any older pending frame (latest wins). During a
   typing burst or fast SSE stream the user always converges to the latest
   visible state with bounded memory.
3. **External wakes are throttled.** `SlateChat.runFullscreen` configures the
   pump with `externalCoalesceMaxFramesPerSecond: 60`, so SSE chunks /
   persistence saves / usage updates produce at most ~60 main-actor renders
   per second regardless of how busy the producer is.
4. **Slow-frame log line.** `event=chat.render.slow elapsed_ms=… prepare_ms=…
   submit_ms=… …` fires when the on-actor portion of a render exceeds 50 ms.
   `prepare_ms` covers transcript flatten + layout (CPU on main actor),
   `submit_ms` covers grid build + encode + writer submission (also on main
   actor; the actual tty drain is off-actor and **not** included).
5. **Tool output truncation in the transcript.** `read_file` results render as
   a single summary line, and shell `stdout` / `stderr` results larger than
   200 lines render as a head + truncation marker + tail (120 + marker + 60).
   The full content is preserved in the conversation history sent to the
   model — the cap only affects the rendered scrollback to keep flatten +
   layout cost bounded after a verbose tool call.

## Logs

Each `scribe chat` invocation writes **one** log file:
`{logDirectoryPath}/scribe-{sessionId}.log` (the same UUID stem as the
`{sessionId}.json` transcript archive). There is no separate diagnostics file.
Resumed sessions append to the existing log so the full history of the session
ID is preserved.

Lines are formatted as

```
<iso8601-ms> [<level>] event=<ns.name> key1=value1 key2=value2 …
```

— for example:

```
2026-05-02T17:44:23.123Z [debug] event=chat.user.submit kind=queue chars=42 newlines=0 replacing=false model_busy=true
```

The leading timestamp makes it easy to align input events against agent stream
timing when debugging input lag, hangs, or surprising state transitions.

### Chat-host events (`SlateChatHost`)

| Event | Sample fields | When it fires |
|---|---|---|
| `chat.session.start` | `session_id model mode max_tool_rounds log_level cwd session_file config_file` | First line of the file — emitted by `Chat.run` once the session id is known. `mode` is `new` or `resume`. |
| `chat.session.resume.model-mismatch` | `archived_model current_model` | Resuming a session saved with a different model than the current config. |
| `chat.fullscreen.attach` | `session_file` | `SlateChat.runFullscreen` accepted the TTY and is starting the host. |
| `chat.fullscreen.fail` | `reason=slate-not-interactive` | Slate refused the terminal. |
| `chat.user.input.newline` | `source buffer_chars has_queue` | Soft newline inserted (Shift+Enter / Alt+Enter / Ctrl+J etc.). `source` distinguishes the encoding: `raw-lf`, `esc-prefix-cr-or-lf`, `csi-u-modified-enter mod=N`, `csi-tilde-modified-enter mod=N`, `csi-tilde-xterm-modified-enter mod=N`. |
| `chat.user.input.paste-begin` / `paste-end` | `buffer_chars` | Bracketed-paste boundaries — handy when correlating large multi-line submits with subsequent submit/queue events. |
| `chat.user.submit kind=immediate` | `chars newlines model_busy=false` | Enter sent the buffer straight to the agent (idle path — first message, between turns, etc.). |
| `chat.user.submit kind=queue` | `chars newlines replacing model_busy=true` | Enter parked the buffer in the queued tray while the agent is busy. `replacing=true` means a previously queued message was overwritten. |
| `chat.user.submit kind=interrupt-and-send` | `chars newlines model_busy` | Enter on an empty buffer with a queued message: interrupted the agent (if busy) and dispatched the queued text. |
| `chat.user.submit kind=noop` | `reason model_busy` | Enter pressed with nothing to submit. |
| `chat.user.ctrl-c action=recall-queue` | `queue_chars model_busy` | Ladder step 1 — queued text pulled back into the input box. |
| `chat.user.ctrl-c action=interrupt-agent` | `model_busy=true` | Ladder step 2 — interrupt requested. |
| `chat.user.ctrl-c action=exit` | `model_busy=false` | Ladder step 3 — exit the chat. |
| `chat.user.ctrl-d action=exit` | — | EOF press at any time. |
| `chat.user.eof` | `reason=stdin-closed` | `readUserLine` returned `nil` (stdin closed). |
| `chat.user.exit-command` | — | User typed `exit` as a submission. |
| `chat.user.empty-skip` | — | Empty submission ignored by the coordinator. |
| `chat.queue.auto-flush` | `trigger=busy-to-idle chars` | Agent finished its turn naturally with a queued message in the tray; the queue is being handed off to the coordinator. |
| `chat.render.slow` | `elapsed_ms prepare_ms submit_ms flat_rows cols rows model_busy queue_chars buffer_chars` | A render frame's on-actor portion took ≥50 ms. `prepare_ms` is transcript flatten + layout; `submit_ms` is grid build + encode + writer submit (the actual tty drain happens off-actor and is **not** included). |
| `chat.persist.save` | `messages path` | Conversation snapshot persisted to disk. |
| `chat.persist.fail` | `path err` | Persistence write failed. |
| `chat.coordinator.start` | `messages resumed` | Coordinator entered its prompt loop. |
| `chat.coordinator.end` | `transcript_messages turns` | Coordinator left its prompt loop normally. |
| `chat.coordinator.fail` | `err` | Coordinator task threw out of `runInteractive`. |
| `chat.session.end` | `status=ok` | Last line of the file. |

### Agent events (`AgentHarness` / `ScribeAgentCoordinator`)

| Event | Sample fields | When it fires |
|---|---|---|
| `agent.turn.dispatch` | `turn chars` | Coordinator pulled a non-empty user line from the gate and is starting a model turn. |
| `agent.turn.start` | `model messages max_tool_rounds` | First action inside `AgentHarness.runModelTurn`. |
| `agent.http.request` | `round payload_messages` | Streaming POST to `chat/completions` was issued. |
| `agent.http.response` | `round status elapsed_ms [body_snippet]` | HTTP response received. `status=200` for success; non-200 includes `body_snippet`. |
| `agent.stream.first-chunk` | `round ttfb_ms` | First decoded SSE chunk arrived. `ttfb_ms` is wall time since the request was issued. |
| `agent.stream.progress` | `round chunks elapsed_ms chunks_per_s` | Periodic progress every 200 chunks. (Per-chunk lines are intentionally not emitted — they drown the signal during long streams.) |
| `agent.stream.end` | `round chunks skipped elapsed_ms prompt_tokens completion_tokens tps` | Stream finished cleanly; usage block included when the server provided one. |
| `agent.stream.empty` | `chunks` | Stream produced no tokens and no tool calls. |
| `agent.stream.unreadable-chunk` | `chunk_index err raw_prefix` | An SSE event failed JSON decoding (decoder skipped). |
| `agent.stream.abort` | `where chunks had_visible_tokens` | Turn was aborted while streaming. `where` is `mid-stream` or `post-stream`. |
| `agent.assistant.final` | `round answer_chars reasoning_chars` | Assistant produced a final reply with no tool calls. |
| `agent.tool.round` | `round tool_count tools` | Assistant requested tool calls; runner is about to execute them. |
| `agent.tool.invoke` | `round tool args_chars output_chars elapsed_ms unknown` | A single tool call completed. |
| `agent.tool.unknown` | `round tool` | Tool runner reported the call name as unknown. |
| `agent.tool.round.end` | `round messages` | All tool calls in a round done; loop will request the next model response. |
| `agent.turn.end` | `turn status [elapsed_ms limit err]` | Coordinator's outcome line per turn. `status` is `completed`, `tool-round-limit`, `interrupted`, or `error`. |
| `agent.turn.tool-round-limit` | `max` | Hit the configured tool-round ceiling without a clean reply. |
| `agent.abort` | `where round [tool]` | Cooperative abort fired between phases (`before-http`, `post-stream-pre-tools`, `pre-tool`). |

## Related code

- `SlateChatHost.submitUserLine` — Enter handling.
- `SlateChatHost.handleKey` (the `byte == 3` branch) — Ctrl+C handling.
- `SlateChatHost.insertNewlineIntoInput` — single recorded path for soft newlines.
- `SlateChatHost.run` — the `readUserLine` wrapper that records to scrollback,
  and the `onEvent` body that runs the busy → idle auto-flush and slow-frame
  trace.
- `SlateTranscriptSink.setQueuedTrayText` /
  `SlateTranscriptSink.queuedTrayTextSnapshot` — thread-safe pipe between the
  host's queue state and the renderer.
- `SlateChatRenderer.queuedTrayRowCount` /
  `SlateChatRenderer.paintQueuedTrayRows` — tray layout and painting.
