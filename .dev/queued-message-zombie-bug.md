# Design Notes: Dual-State Queued Message Bug (fixed in a74a8cd)

## The Bug

`queuedTrayText` in `SlateChatHost` would become a "zombie" — lingering in the UI
forever after its corresponding message had already been dispatched.

## Root Cause

Two copies of the same state existed in two places:

| Location | Field | Purpose |
|---|---|---|
| `SubmitCoordinator` | `queuedText` | State machine truth |
| `SlateChatHost` | `queuedTrayText` | UI rendering copy |

The coordinator correctly cleared `queuedText = nil` when consuming a queued
message (returning `.sendToGate` or `.interruptAndSend`). But `applySubmitEffect`
in the host was not mirroring those clears — it only cleared `queuedTrayText` in
the `.setQueued` / `.clearQueued` / auto-flush paths.

### Specific stale-path

1. Model busy, user enters text → queued (both copies set).
2. Model finishes → but auto-flush hasn't fired yet (it happens on the next
   render frame, scheduled after a delay).
3. User presses empty-Enter before that frame → `SubmitCoordinator.handleEnter("")`
   consumes the queued text, sets `queuedText = nil`, returns `.sendToGate(...)`.
4. `applySubmitEffect(.sendToGate(...), ...)` dispatches to the gate but did
   **not** clear `queuedTrayText`.
5. The next render frame shows a stale tray message that's already been sent.
6. Auto-flush runs → `queuedText` is already nil → does nothing. The zombie
   `queuedTrayText` survives until the next queuing operation overwrites it.

The same zombie path existed for `.interruptAndSend` (empty-Enter while model
is busy with queued text).

## The Fix (a74a8cd)

Added `queuedTrayText = nil` to both the `.sendToGate` and `.interruptAndSend`
arms of `applySubmitEffect`.

## Why Tests Didn't Catch This

`SubmitCoordinatorTests` tests the coordinator state machine in isolation and
correctly verifies that `queuedText` is cleared. But the host's `queuedTrayText`
is a separate variable — no integration test covered the host's mirroring of
coordinator state into UI state.

The coordinator returns `SubmitEffect` enum cases; the host's job is to *apply*
those effects, including clearing its own UI mirror. The tests verified the
effect values, not the host's side-effect completeness.

## Design Lessons — How To Avoid This Class of Bug

### 1. Single source of truth (SSOT)

The core problem is that `queuedText` and `queuedTrayText` are two variables
representing the same fact. Any design with duplicated state will eventually
drift. Options:

- **Expose, don't copy.** Let the host read `submitCoordinator.queuedText`
  directly for rendering instead of maintaining a separate `queuedTrayText`.
  (Currently `queuedText` is `private(set)` — making it readable eliminates
  the copy entirely.)

- **Invert the relationship.** Instead of the host mirroring coordinator state,
  the coordinator could own the UI-relevant value and the host reads it:

  ```swift
  // Coordinator owns the single value
  struct SubmitCoordinator {
      private(set) var queuedText: String? = nil  // already exists
      // host reads this directly; no host-side copy needed
  }
  ```

  Then in the render path:
  ```swift
  // Instead of self.queuedTrayText:
  let trayText = self.submitCoordinator.queuedText
  ```

### 2. Effect handlers should be exhaustive and derived

`applySubmitEffect` is a hand-written switch over `SubmitEffect`. Every arm
should be checked for completeness against the host's state invariants:

- `.sendToGate` → must clear UI queued state + send to gate
- `.interruptAndSend` → must clear UI queued state + interrupt + send
- `.setQueued` → must set UI queued state
- `.clearQueued` → must clear UI queued state
- `.interruptModel` → must set interrupt flag
- `.exitChat` → must return stop
- `.none` → nothing

A comment on each arm listing the required host-side mutations would have
made the missing `queuedTrayText = nil` glaringly obvious during review.

### 3. Integration tests for effect application

`SubmitCoordinator` is pure and well-tested. But `applySubmitEffect` (the glue
between coordinator output and host state) has no tests. An integration test
that feeds coordinator effects through `applySubmitEffect` and asserts on the
resulting host state would have caught this:

```
Given: queuedTrayText = "hello", modelBusy = false
When: applySubmitEffect(.sendToGate("hello"))
Then: queuedTrayText == nil  // ← this was failing before the fix
```

### 4. Property-based or model-based testing for state machines

The host's state (`queuedTrayText`, `modelBusy`, `coordinatorFinished`) forms
an ad-hoc state machine alongside `SubmitCoordinator`. A model-based test
could enumerate all `(hostState, SubmitEffect)` pairs and verify that no
effect leaves `queuedTrayText` non-nil when the coordinator's `queuedText` is nil:

```
Invariant: submitCoordinator.queuedText == nil ⟹ queuedTrayText == nil
```

This invariant was violated by the bug.

### 5. "Zombie state" is a smell — prefer making illegal states unrepresentable

Rather than clearing `queuedTrayText` in every effect arm, consider whether
the concept of "queued tray text" can be derived rather than stored:

```swift
// Derived, never stale:
var trayText: String? {
    submitCoordinator.queuedText
}
```

Or if it must be stored (e.g., for rendering performance), use a computed
property backed by the coordinator and optionally cache it with a generation
counter that invalidates on coordinator mutation — the same pattern already
used by `FlattenCache`/`transcriptGeneration` in this same file.

## Broader Pattern

This bug is an instance of a common pattern:

> **Mirrored state that is cleared in some but not all consumption paths.**

The same pattern could apply to any host-side copy of state that lives in a
sub-component (coordinator, input handler, viewport). Each copy is a liability.
Each clearing site is a potential miss.

### Audit checklist for similar issues in this codebase

- `inputHandler.buffer` vs any host-side copy of input state
- `viewport` scroll state vs any host-side copy
- `modelBusy` in host vs any coordinator-side busy tracking
- Any other `private var` in `SlateChatHost` that shadows state in an extracted
  component (`inputHandler`, `submitCoordinator`, `viewport`)
