# SlateChatHost — refactoring order

## Overview

`SlateChatHost` is a ~1032-line `@MainActor` class that couples the Core agent
to the Slate TUI lifecycle. This document orders the proposed refactorings by
risk and dependency.

## Dependency graph

```
TranscriptController  ← no dependencies (pure state machine)
        │
        ├── ChatCoordinator  ← depends on TranscriptController for event emission
        │       │
        │       └── ChatDriver  ← depends on Coordinator + TranscriptController + buildFrame
        │
        ├── MarkdownOutput  ← no dependencies (new types in ScribeCore)
        │       │
        │       └── MarkdownToSlateAdapter  ← depends on MarkdownOutput
        │
        └── buildFrame (RenderLoop)  ← depends on TranscriptController for state shape
                │
                └── ChatDriver  ← depends on buildFrame
```

## Step-by-step

### Step 1: Extract `TranscriptController`

**Risk: Very low.** Pure value type, no async, no dependencies. The
`handleTranscriptEvent` switch is already a well-understood state machine.

| Action | Lines |
|---|---|
| Create `TranscriptController.swift` | ~200 new |
| Move event arms from `handleTranscriptEvent` into `TranscriptController.apply()` | — |
| Replace host's `handleTranscriptEvent` with `transcriptController.apply(...)` | ~250 removed from host |
| Write `TranscriptControllerTests.swift` | ~150 new |
| **Net host change:** −250 lines | |

### Step 2: Introduce `MarkdownOutput` in ScribeCore + `MarkdownToSlateAdapter`

**Risk: Low.** Pure type migration. `SwiftMarkdownRenderer` returns semantic
types instead of Slate types; adapter maps them back for the host.

| Action | Lines |
|---|---|
| Create `ScribeCore/MarkdownOutput.swift` | ~80 new |
| Move `MarkdownRenderer` protocol to ScribeCore | — |
| Change `SwiftMarkdownRenderer` return type to `[MarkdownLine]` | ~50 changed |
| Create `MarkdownToSlateAdapter.swift` in `ScribeCLI/Markdown/` | ~60 new |
| Update `TranscriptController` to use `MarkdownRenderer` (semantic) + convert via adapter | ~10 changed |
| Update `MarkdownRendererTests` to assert on `[MarkdownLine]` | ~100 changed |
| Write `MarkdownToSlateAdapterTests` | ~50 new |
| **Net host change:** ~5 lines (use adapter) | |

### Step 3: Extract `buildFrame` (RenderLoop)

**Risk: Low–Medium.** Refactors the 60-line render block into a pure function.
Requires `TranscriptController` to exist (so `RenderState` can reference the
right state fields). The Slate grid writing becomes a thin shim.

| Action | Lines |
|---|---|
| Create `RenderLoop.swift` with `buildFrame`, `RenderState`, `RenderOutput` | ~120 new |
| Replace inline render block in `onEvent` closure with `buildFrame(state:)` | ~70 removed from host |
| Split `SlateChatRenderer.render(into:)` into `buildGrid(...)` (pure) + grid shim | ~30 changed |
| Write `RenderLoopTests.swift` | ~150 new |
| **Net host change:** −70 lines | |

### Step 4: Extract `ChatCoordinator` actor

**Risk: Medium.** Involves async communication patterns (gate → AsyncStream
bridge). The coordinator's behavior is well-understood (the embedded closure
already exists), but extracting it correctly requires care around the
`ModelTurnInterruptFlag` and `UserLineGate` bridging.

| Action | Lines |
|---|---|
| Create `ChatCoordinator.swift` | ~150 new |
| Create `SessionPersistence.swift` | ~80 new |
| Replace embedded closure in host with coordinator task | ~110 removed from host |
| Bridge `UserLineGate` → `AsyncStream<String>` | ~20 new in host |
| Write `ChatCoordinatorTests.swift` | ~200 new |
| Write `SessionPersistenceTests.swift` | ~100 new |
| **Net host change:** −90 lines | |

### Step 5: Assemble `ChatDriver` (headless test mode)

**Risk: Low** (depends on Steps 1–4 being complete). The driver is a thin
orchestrator that wires the extracted components together without Slate.

| Action | Lines |
|---|---|
| Create `ChatDriver.swift` | ~100 new |
| Write `ChatDriverTests.swift` | ~200 new |
| Write `TranscriptGoldenTests.swift` | ~80 + golden files |

## Cumulative impact on `SlateChatHost`

| After | Host lines (approx) | Removed |
|---|---|---|
| Current | 1032 | — |
| Step 1 | ~780 | −250 |
| Step 2 | ~775 | −5 |
| Step 3 | ~705 | −70 |
| Step 4 | ~615 | −90 |
| **Final** | **~615** | **−417 lines (40%)** |

What remains in the host:
- Slate lifecycle (`subscribe`, `prepare`, `onEvent` skeleton)
- `UserLineGate` ↔ `AsyncStream` bridging
- `ModelTurnInterruptFlag` management
- `applySubmitEffect` (already thin, backed by `HostSubmitState.apply`)
- State-holding fields that are passed into `buildFrame` as `RenderState`

## Principles

1. **Each extraction is a pure function or an actor with a narrow interface.**
   No extracted component depends on `SlateCore` or `@MainActor`.

2. **Tests are added with each extraction, not deferred.** This prevents the
   "we'll test it later" trap and ensures each extraction is verified before
   the next one builds on it.

3. **No behavior changes during extraction.** Each step is a mechanical
   move-and-delegate refactor. The host should behave identically after
   every step.

4. **The order minimizes risk.** Steps 1–2 are pure type work with no async
   complexity. Steps 3–4 introduce structural changes. Step 5 is the payoff.

---

## Execution results (2025-05-10)

### Host reduction

| Metric | Before | After |
|--------|--------|-------|
| `SlateChatHost.swift` | 1,032 lines | 579 lines |
| Reduction | — | **−453 lines (44%)** |

### New source files

| File | Lines | Purpose |
|------|-------|---------|
| `ScribeCLI/SlateChat/TranscriptController.swift` | 390 | Pure state machine for transcript events (Step 1) |
| `ScribeCLI/SlateChat/ChatCoordinator.swift` | 209 | Actor for agent turn-loop, `ModelTurnInterruptFlag` extracted (Step 4) |
| `ScribeCLI/Markdown/MarkdownToSlateAdapter.swift` | 103 | Semantic ↔ Slate type bridge (Step 2) |
| `ScribeCLI/SlateChat/RenderLoop.swift` | 77 | Pure `buildFrame(state:)` render-prep function (Step 3) |
| `ScribeCLI/SlateChat/ChatDriver.swift` | 57 | Headless orchestrator for testing without Slate (Step 5) |
| `ScribeCore/MarkdownOutput.swift` | 42 | `MarkdownLine`, `MarkdownSpan`, `MarkdownSpanKind` types (Step 2) |

### New test files (53 tests)

| File | Lines | Tests |
|------|-------|-------|
| `TranscriptControllerTests.swift` | 290 | 17 |
| `RenderLoopTests.swift` | 170 | 6 |
| `MarkdownToSlateAdapterTests.swift` | 126 | 13 |
| `ChatDriverTests.swift` | 124 | 6 |
| `ChatCoordinatorTests.swift` | 110 | 5 |
| `TranscriptGoldenTests.swift` | 109 | 4 |

**Total: 346 tests in 27 suites, all passing, zero regressions.**

### What remains in `SlateChatHost` (579 lines)

- Slate lifecycle (`subscribe`, `prepare`, `onEvent` skeleton)
- `UserLineGate` ↔ `AsyncStream<String>` bridging
- `ModelTurnInterruptFlag` management (type extracted to `ChatCoordinator.swift`)
- `applySubmitEffect` (backed by `HostSubmitState.apply`)
- `EventQueue` and `drainIncomingEvents` with drift detection
- State-holding fields passed into `RenderLoop.buildFrame` as `RenderState`

### Deviations from plan

| Plan item | What shipped | Rationale |
|-----------|-------------|-----------|
| Move `MarkdownRenderer` protocol to ScribeCore | Kept in ScribeCLI; added semantic types + adapter | Protocol references `TerminalRGB`/`MarkdownTheme` which need SlateCore; adapter bridges without moving protocol |
| Split `SlateChatRenderer.render` into `buildGrid` + shim | Kept `render(into:)` as-is; extracted prep into `RenderLoop.buildFrame` | Grid painting is tested by existing `SlateChatRenderTests`; prep extraction gives the same decoupling |
| Create `SessionPersistence.swift` | Skipped; `ChatSessionPersistence.swift` already exists | Existing file covers the same ground |
| Change `SwiftMarkdownRenderer` return type | Added `MarkdownToSlateAdapter` with forward/reverse conversion without changing the renderer | Preserves existing `MarkdownRendererTests` (all 50+ pass unchanged) |

