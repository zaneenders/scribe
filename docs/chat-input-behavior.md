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

## Related code

- `SlateChatHost.submitUserLine` — Enter handling.
- `SlateChatHost.handleKey` (the `byte == 3` branch) — Ctrl+C handling.
- `SlateChatHost.run` — the `readUserLine` wrapper that records to scrollback,
  and the `onEvent` body that runs the busy → idle auto-flush.
- `SlateTranscriptSink.setQueuedTrayText` /
  `SlateTranscriptSink.queuedTrayTextSnapshot` — thread-safe pipe between the
  host's queue state and the renderer.
- `SlateChatRenderer.queuedTrayRowCount` /
  `SlateChatRenderer.paintQueuedTrayRows` — tray layout and painting.
