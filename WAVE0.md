# Wave 0 — Baseline and fixtures

## Baseline (before this change)

```text
swift build   # Build complete!
swift test    # 2 + 58 + 306 + 43 tests passed across 4 targets
```

Existing failures: none. Baseline was green.

## Production seams

Only test-enabling visibility changes, no behavior change:

- `Sources/ScribeMac/SessionController.swift`: `replay` and `reduce` changed from `private` to internal.
- `Package.swift`: `ScribeBlocksTests` gains `ScribeCore`, `ScribeKit`, and `ScribeLLM`
  dependencies so it can build an in-memory `SessionHarness` with a scripted agent.

## New characterization tests

`Tests/ScribeBlocksTests/SessionControllerTestSupport.swift`

- scripted `ClientTransport`, cancellation-aware first-call gate, in-memory boots.

`Tests/ScribeBlocksTests/SessionControllerTests.swift`

- `TranscriptReplayTests` — persisted message → transcript item mapping (kinds, titles,
  source indices, tool output attachment, system/empty skipping, init replay).
- `EventReductionTests` — reasoning/answer sections, repeated section start, empty output,
  usage, error/retry/recovery/warning, tool start/end upsert, ignored events.
- `SubmitAndQueueTests` — submit streaming, blank draft, queue-while-running then drain,
  clear queue, stop preserving queue, force-send-next.
- `ForkIdentityTests` — fork changes session id/directory, clears pin, notifies identity change.

`Tests/ScribeCoreTests/SessionHarnessTests.swift`

- reconfigure updates the configuration snapshot and persists profile; nil profile persists;
  `forkSplice` replaces the range and returns an identity change (TLDR mechanism).

`Tests/ScribeKitTests/SessionPresentationCharacterizationTests.swift`

- rename trimming, clear-name with pin/recency preserved, pin toggle preserving name/recency,
  no-op presentation update, configuration update preserving name/pin.

After this change:

```text
swift build   # Build complete!
swift test    # 2 + 63 + 309 + 61 tests passed across 4 targets
```
