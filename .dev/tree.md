# Session Trees

## Overview

Scribe sessions are flat directories (`sessions/{uuid}/` with `metadata.json` +
`messages.jsonl`). This design adds **session switching**, **forking**, and
**tree navigation** without introducing a shared node graph. Each fork is a
full independent copy of the session directory. Lineage is tracked via small
pointers in `metadata.json`.

---

## Phase 1 — Slash Commands + `/switch`

### Why this first

`/switch` needs zero new data model. `ChatSessionStore.save()`, `.load()`,
`.resolveResumeURL()`, and `TranscriptReplay.replay()` all exist. The only new
piece is a slash-command parser and the ability to restart the coordinator task
with a different session's messages.

### Slash-command parser

**New:** `ScribeCore/SlashCommand.swift`

```swift
enum SlashCommand {
    case `switch`(String)        // /switch {prefix}
    case fork(String?, String?)  // /fork [prefix] [label]
    case tree(String?)           // /tree [prefix]
    case branches                // /branches
    case prune(String)           // /prune {prefix}
}

struct SlashCommandParser {
    static func parse(_ input: String) -> SlashCommand?
}
```

### `/switch` command

```
/switch a1b2          # switch to session with prefix a1b2
/switch latest        # switch to most recently modified session
```

1. **Parse** — `SlashCommandParser` recognizes `/switch` and extracts the prefix
2. **Save** — flush current session's messages to its `messages.jsonl`, update
   `metadata.json` (same persist that already happens after every turn)
3. **Cancel** — cancel the current coordinator task (the `while true` loop in
   `ScribeAgent.runInteractive`)
4. **Resolve** — `ChatSessionStore.resolveResumeURL(specifier:)` finds the
   target session directory
5. **Load** — `ChatSessionStore.load(from:)` reads `metadata.json` +
   `messages.jsonl` into a `ChatSessionArchive`
6. **Spawn** — start a new coordinator task with the loaded messages as
   `initialConversation`, just like `--resume` does at startup
7. **Redraw** — `TranscriptReplay.replay()` rebuilds the scrollback

### Source changes

| File | Change |
|------|--------|
| **New:** `ScribeCore/SlashCommand.swift` | Command enum + parser |
| **Modify:** `SlateChatHost.swift` | Intercept `/`-prefixed lines in `submitUserLine`; coordinator restart for `/switch` |

---

## Phase 2 — Session Lineage + `/fork`

### Model: fork by copying

A fork is a full independent copy of the session directory. Each session stays
a self-contained flat directory with `metadata.json` + `messages.jsonl` —
exactly as it works today. No shared state, no node graph, no migration.

Lineage is tracked with additions to `metadata.json`:

```jsonc
// metadata.json (existing fields + new optional fields)
{
  "schemaVersion": 2,           // bumped from 1
  "id": "uuid-of-this-session",
  "createdAt": "ISO8601",
  "model": "...",
  "cwd": "...",
  "baseURL": "...",

  // NEW — absent for root sessions, present for forks (back-pointer)
  "forkedFrom": {
    "sessionId": "uuid-of-parent",
    "atMessageId": "msg-abc123",  // UUID of the message at the fork point
    "label": "explore sqlite"     // optional human label
  },

  // NEW — absent for leaf sessions, present when something forks from this (forward-pointer)
  "forkedTo": [
    { "sessionId": "uuid-of-child", "label": "explore sqlite" }
  ]
}
```

**Why forward pointers (`forkedTo`)?** Without them, `/tree` must scan every
session directory and read every `metadata.json` to reconstruct the tree — O(n)
where n = all sessions ever. With `forkedTo` written into the parent at fork
time, tree walking is O(depth): start at the root (which has no `forkedFrom`)
and follow `forkedTo` links down. The scan is only needed as a fallback if a
parent wasn't updated (e.g. the parent session was deleted).

**Why message IDs?** The fork point is identified by a message UUID
(`atMessageId`) rather than a line index. This is robust against any future
message-file rewrites and makes the fork point unambiguous. The cost is small:
each message in `messages.jsonl` gets an `"id": "msg-{uuid}"` field.

```jsonl
{"role":"system","content":"You are Scribe...","id":"msg-00000000-0000-0000-0000-000000000001"}
{"role":"user","content":"fix the auth bug","id":"msg-00000000-0000-0000-0000-000000000002"}
```

Messages written before this feature ships simply lack an `id` field — fork
points for those fall back to `atMessageIndex` (line number), which is stable
because messages are append-only.

### `/fork` command

```
/fork                          # fork current session at latest message
/fork "explore sqlite"         # fork with a label
/fork a1b2 "try postgres"      # fork from session a1b2 at its latest message
```

1. Copy the entire session directory to a new UUID
2. Truncate `messages.jsonl` in the clone to the fork point (messages before
   the fork are preserved; messages after are dropped in the new branch)
3. Write `forkedFrom` into the clone's `metadata.json`
4. Append to the **parent's** `forkedTo` array in its `metadata.json`
5. Switch to the new clone (same mechanism as `/switch`, Phase 1)

### Source changes

| File | Change |
|------|--------|
| **New:** `ScribeCore/SessionLineage.swift` | `ForkedFrom`/`ForkedTo` types, tree-walk logic |
| **Modify:** `ChatSessionPersistence.swift` | Add `forkedFrom`/`forkedTo` to metadata; clone/truncate helpers; message ID generation |
| **Modify:** `SlashCommand.swift` | Add `fork` case |
| **Modify:** `SlateChatHost.swift` | Handle `/fork` command |

---

## Phase 3 — `/tree`, `/branches`, `/prune`

### `/tree` command

```
/tree                          # show tree from root
/tree a1b2                     # show tree scoped to session a1b2
```

**Fast path:** Find the root (no `forkedFrom`), walk `forkedTo` links forward
depth-first. O(depth).

**Fallback:** If `forkedTo` is missing from a session (old sessions, deleted
children), scan all session directories and rebuild forward links on the fly.
O(n).

Output is an ASCII tree:

```
▼ a1b2c3d4  (current)  12m ago  "explore sqlite"
│   forked from  ▼ 0f1e2d3c  1h ago  "initial session"
                 ├── ● a1b2c3d4  12m ago  "explore sqlite"
                 └── ▼ b2c3d4e5  30m ago  "try postgres"
```

- `▼` = has children (collapsed)
- `●` = leaf (current session)
- `(current)` = the active session
- Label shown in quotes after the timestamp

### `/branches` command

```
/branches                      # list all leaf sessions
```

Lists sessions that nothing has forked from (no `forkedTo` entries pointing to
them, or `forkedTo` is empty). These are the "active tips" of the tree.

### `/prune` command

```
/prune a1b2                    # delete session a1b2 (only if it's a leaf)
```

1. Verify the session is a leaf (nothing forks from it)
2. Delete the session directory
3. Remove the entry from the parent's `forkedTo` array

### Source changes

| File | Change |
|------|--------|
| **Modify:** `SessionLineage.swift` | Add tree-walk + ASCII rendering |
| **Modify:** `SlashCommand.swift` | Add `tree`, `branches`, `prune` cases |
| **Modify:** `SlateChatHost.swift` | Handle new commands |
| **Modify:** `SlateChatRenderer.swift` | ASCII tree rendering for `/tree` output |

---

## Full Source Change Summary

| File | Phase | Change |
|------|-------|--------|
| **New:** `ScribeCore/SlashCommand.swift` | 1 | Command enum + parser |
| **New:** `ScribeCore/SessionLineage.swift` | 2 | `ForkedFrom`/`ForkedTo` types, tree-walk logic |
| **Modify:** `SlateChatHost.swift` | 1–3 | Slash commands, coordinator restart, fork, tree |
| **Modify:** `ChatSessionPersistence.swift` | 2 | `forkedFrom`/`forkedTo` in metadata; clone/truncate; message IDs |
| **Modify:** `SlateChatRenderer.swift` | 3 | ASCII tree rendering |

---

## Key Design Decisions

1. **Fork = clone.** No shared state, no node graph, no migration. Each branch
   is a full independent session directory. The only link is a tiny
   `forkedFrom`/`forkedTo` pointer in `metadata.json`.

2. **Forwards + backwards pointers in metadata.** `forkedFrom` lets any session
   find its parent. `forkedTo` lets the parent enumerate its children — so
   `/tree` walks O(depth) instead of scanning O(n) sessions.

3. **Message IDs for robust fork points.** Messages get a `"msg-{uuid}"` `id`
   field. Fork points reference the message ID rather than a fragile line index.
   Old messages without IDs fall back to line number.
