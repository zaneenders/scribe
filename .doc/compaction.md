# Rope-backed session history

Replace the flat `[ChatMessage]` array with a `Rope<[ChatMessage]>` from `swift-collections` for the in-memory conversation store.

## Why

Currently the conversation is a flat array. At scale (400+ messages, 2+ MB) this has problems:

- **Context editing** — delete or replace message 47 and elements 48..434 all shift, O(n).
- **Context window trimming** — drop oldest messages with `removeFirst(k)`, O(n) shift.
- **Serialization for every API call** — `buildRequest(messages:)` materializes the full array. Only the last few turns changed, but we pay for all of it.
- **Persist rewrites the entire file** — `ChatSessionStore.save` writes every message every time. With atomic writes, that's 2.1 MB of I/O per persist, hundreds of times per session.

## What a rope gives

```
Rope<[ChatMessage]>   (balanced tree of chunks)

  [sys] [turn1] [turn2] [turn3] ... [turnN]
          ↑                         ↑
      immutable               dirty (just written)
```

- **Append** — O(log n), same ergonomics as array.
- **Context editing** — O(log n) to find the chunk containing the target message. Modify the chunk in-place, tree rebalances. If chunks are sized ~one turn, editing within a turn only touches one chunk.
- **Context window trimming** — split the rope at the desired boundary, keep the suffix. O(log n).
- **Lazy serialization** — cache serialized JSON per chunk. API requests concatenate cached chunks. Only re-serialize dirty chunks (the last few turns). Most of the history is a no-op.
- **Incremental persistence** — track which chunks are dirty since last save. Append only dirty chunks to `messages.jsonl` (already supported via `ChatSessionStore.appendMessages`). Periodically compact by rewriting the full file and removing superseded chunks.

## Chunk sizing

One user turn per chunk: `[userMessage, assistantMessage?, toolResult*, ...]`. Typically 2–10 messages. Aligns with existing turn boundaries in `TranscriptReplay`. Edit within a turn touches one chunk; edit crossing turns is O(log n).

