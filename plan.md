# Shared Scribe session workspace

## Outcome

This is an in-place refactor of the existing Scribe implementation, not a rewrite or a second implementation. Current standalone behavior is the compatibility baseline. Move that behavior behind reusable APIs, preserve it with characterization tests, and delete the superseded code only after the existing macOS and Wayland applications consume the replacement.

The existing Scribe applications must be the first production consumers of the result. They render a public `ScribeBlocks` workspace driven by a transport-neutral `ScribeKit` presentation model and use `LocalScribeSessionService` for all current session behavior.

The same local service must also be usable from a headless server process. A server can provide explicit paths and working directories, then list, create, open, submit to, interrupt, and update persisted Scribe sessions without importing Chroma or relying on process-wide environment or current-directory mutation. Implementing an HTTP server or a specific remote client is outside this plan.

Reuse the current runtime rather than replacing it: `LocalScribeSessionService` adapts `ScribeSessionBootstrap`, `SessionHarness`, `ChatSessionStore`, `FileSessionPersister`, and `ConfigLoader`. The refactor changes ownership and dependency boundaries; it does not introduce a parallel agent, persistence format, transcript behavior, or queue implementation.

## Current implementation

- `ScribeKit` depends on `ScribeCore` and does not depend on Chroma.
- `ScribeBlocks` is built from `Sources/ScribeMac` and currently contains both reusable blocks and app state.
- `ScribeMacStore` owns saved/open session selection and local filesystem behavior.
- `SessionController` owns transcript replay, event reduction, queueing, interruption, profile changes, fork, and TLDR.
- `ScribeSessionBootstrap.open` and `ConfigLoader.load` resolve process environment and current directory internally.
- `ChatSessionStore` persists metadata and `ScribeMessage` JSON Lines.
- `SessionHarness` serializes actor state, persists completed turn messages, drains `SessionMessageQueue`, supports interruption and reconfiguration, and applies fork and fork-splice edits.

## Refactor constraints

1. Preserve the existing session file format and compatibility with sessions already stored by Scribe unless a tested migration is explicitly required.
2. Preserve current standalone behavior: new, resume, switch, queue, force-next, clear queue, interrupt, rename, clear name, pin, profile switching, fork, TLDR, transcript replay, unread activity, and focus behavior.
3. Move existing logic to its new owner before deleting it. Do not independently reimplement behavior in a new layer and leave both paths active.
4. The macOS and Wayland applications must consume the shared workspace and local service before the old store/controller behavior is removed.
5. `ScribeKit` remains free of Chroma and suitable for a headless server process.
6. `ScribeBlocks` depends on public `ScribeKit` contracts, not `SessionHarness`, `ChatSessionStore`, or local paths.
7. Library entry points accept explicit paths. Environment-resolving convenience APIs are standalone wrappers.
8. Persistence is authoritative. Loaded runtimes are caches and may be discarded after a turn.
9. Mutable runtime state is actor-isolated; UI state is `@MainActor`; do not use `@unchecked Sendable`.
10. Transcript replay, streamed event reduction, and queue policy each have one active implementation in `ScribeKit`.
11. Do not keep a legacy UI path or feature flag after standalone parity is reached.
12. Never change `HOME`, `SCRIBE_HOME`, or process current directory to configure a session.

## Public ScribeKit contract

Finalize names in the contract change before adapter or UI migration begins. Later agents should change the contract only with tests and an explicit migration note.

### Values

Add public `Codable`, `Sendable`, and `Equatable` values where their fields permit it:

- `ScribeSessionSummary`
  - `id`, `name`, `isPinned`, `createdAt`, and `lastMessageAt`
  - `workingDirectory`, `profileName`, and `model`
- `ScribeSessionSnapshot`
  - summary
  - persisted `[ScribeMessage]`, including the system message
  - profile catalog if needed to render profile controls immediately
- `ScribeProfileSummary`
  - replace or rename the existing `ProfileSummary`; do not create two profile summary types
- `ScribeTranscriptItem`
  - stable ID, kind, title, body, running state, and optional source-message position
  - no Chroma layout, scroll, focus, or selection state
- request and update values for create, presentation changes, reconfiguration, fork, and TLDR
- `ScribeSessionServiceError`
  - at least `notFound`, `busy`, `unsupported`, `invalidRequest`, and a display-safe failure
- `ScribeSessionCapabilities`
  - advertises profile switching, fork, TLDR, and directory selection support

Continue using `ScribeMessage` as the persisted transcript source. Do not add a parallel message model without a wire-format requirement.

`ScribeTranscriptItem.ID` must be reproducible for replayed persisted messages and remain unchanged while streamed text is appended. Base replay IDs on session ID plus source message position, segment, or tool-call identity. Stream mapping must use the same scheme or reconcile provisional IDs when a terminal snapshot is applied. Add tests before UI code depends on this behavior.

### Stream events

Add one Codable tagged enum, `ScribeSessionEvent`, with enough structured data for the shared reducer:

- accepted user prompt;
- reasoning and answer section start and delta;
- tool round start;
- tool invocation start and completion;
- warning, retry, recovery, usage, and empty output;
- interruption;
- session identity change after fork-like operations;
- terminal completion with a `TurnOutcome`-equivalent Codable value;
- terminal failure with a display-safe error.

Do not use display-formatted transcript strings as event semantics. The shared reducer owns titles and presentation decisions.

Every successful stream emits exactly one terminal event and then finishes. A stream may throw only for setup failure or an unexpected disconnection. Adapters preserve event ordering. Unknown future event tags fail explicitly rather than being treated as completion.

### Service

Use request values instead of accumulating positional parameters. The target surface is:

```swift
public protocol ScribeSessionService: Sendable {
  func capabilities() async -> ScribeSessionCapabilities
  func listSessions() async throws -> [ScribeSessionSummary]
  func listProfiles() async throws -> [ScribeProfileSummary]
  func createSession(_ request: ScribeCreateSessionRequest) async throws -> ScribeSessionSnapshot
  func openSession(id: UUID) async throws -> ScribeSessionSnapshot
  func submit(_ request: ScribeSubmitRequest) async throws
    -> AsyncThrowingStream<ScribeSessionEvent, any Error>
  func interrupt(sessionID: UUID) async throws
  func updatePresentation(_ request: ScribePresentationUpdate) async throws
    -> ScribeSessionSummary
  func reconfigure(_ request: ScribeReconfigureSessionRequest) async throws
    -> ScribeSessionSnapshot
  func fork(_ request: ScribeForkSessionRequest) async throws -> ScribeSessionSnapshot
  func summarize(_ request: ScribeSummarizeSessionRequest) async throws
    -> ScribeSessionSnapshot
}
```

`ScribePresentationUpdate` must distinguish "leave name unchanged" from "clear name". Separate rename and pin methods are also acceptable.

The service accepts one active submission per session. A second direct submission returns `busy`. Queueing belongs to the shared workspace model, which starts the next service submission after the prior terminal event. Different session IDs may run concurrently. `interrupt` is idempotent.

### Workspace model

Add a public `@MainActor`, `@Observable` workspace model in `ScribeKit`. It owns:

- saved summaries, open snapshots, active selection, and per-directory grouping;
- loading, empty, and recoverable error state;
- transcript replay and incremental event reduction;
- draft, prompt history, queued prompts, force-next, and clear-queue behavior;
- active-turn state, interruption, unread activity, and terminal cleanup;
- rename, pin, profile, fork, and TLDR actions when capabilities allow them;
- stable transcript identity throughout replay and streaming.

Keep these outside the model:

- Chroma focus, scroll controllers, text layout caches, and selection state;
- shell capture and profile recorder lifecycle;
- local directory browsing and completion;
- transport authentication and serialization;
- direct filesystem and `ScribeAgent` access.

Use an injected host action for choosing a working directory so path selection remains outside the reusable workspace.

## Explicit local runtime

Add an explicit context before implementing the local service:

```swift
public struct ScribeRuntimeContext: Sendable {
  public var paths: ScribePaths
  public var configurationFile: FilePath?
  public var defaultWorkingDirectory: String
  public var version: String
}
```

Required APIs:

- `ConfigLoader.resolvePaths(...)` and `load(...)` overloads taking explicit `ScribePaths` and an optional configuration file;
- `ScribeSessionBootstrap.open(...)` taking `ScribeRuntimeContext`;
- existing convenience overloads delegating to explicit overloads;
- no explicit overload reading environment variables or `FilePath.currentDirectory`;
- no explicit call writing a default config outside the supplied `ScribePaths`.

Tests create two temporary homes in one process, load/create/open sessions in both, and prove no cross-contamination without changing environment variables or current directory.

## LocalScribeSessionService

Implement an actor in `ScribeKit` using:

- `ScribeSessionBootstrap`;
- `SessionHarness`;
- `SessionMessageQueue` only below the service if still needed by a single submitted turn;
- `ChatSessionStore` and `FileSessionPersister`;
- `ConfigLoader` and explicit `ScribeRuntimeContext`.

Responsibilities:

- list metadata without loading agents;
- lazily bootstrap an existing session by UUID;
- own at most one loaded runtime per session ID;
- reject overlapping direct submissions for one session;
- map `AgentEvent` and `TurnOutcome` to `ScribeSessionEvent` through one mapper;
- persist before emitting terminal success;
- update rename and pin metadata for loaded and unloaded sessions;
- reconfigure profiles and return refreshed snapshots;
- carry identity changes through fork and TLDR and re-key the runtime cache;
- discard idle runtime caches without affecting persisted sessions.

Do not drain queues in both `SessionHarness` and the workspace. Prefer moving user-visible multi-prompt queue policy to the workspace and making one service submission represent one logical prompt. Preserve current behavior with focused queue and interruption tests before deleting old code.

## Reusable ScribeBlocks surface

Export one embeddable entry point, provisionally:

```swift
public struct ScribeWorkspace: Block {
  public init(model: ScribeWorkspaceModel, host: ScribeWorkspaceHost = .init())
}
```

`ScribeWorkspaceHost` contains only integrations the shared model cannot own, such as directory selection and optional focus or key-binding hooks.

Refactor and export:

- session sidebar and grouping;
- transcript and Markdown rendering;
- composer and queued-message tray;
- running, loading, empty, and error states;
- rename and pin controls;
- supported profile, fork, and TLDR controls;
- theme inputs needed for embedding.

The reusable workspace must not reference `ScribeMacStore`, `SessionController`, `BootstrappedSession`, `SessionHarness`, or `FilePath`. Remove `ScribeBlocks`' direct `ScribeCore` dependency when no reusable block imports it. Move presentation formatting needed by blocks into `ScribeKit` instead of retaining runtime coupling.

The standalone shell may retain the app header, profile recorder, shell capture, directory palette, scene capture, and platform window lifecycle.

## Execution plan

Agents work in the following merge order. Work may be parallelized only where noted.

### Wave 0 — Baseline and fixtures

Owner: one Scribe agent.

1. Run `swift build` and `swift test`; record existing failures in the change.
2. Add focused characterization tests for transcript replay, event reduction, queue and interruption behavior, rename clearing, pinning, profile reconfiguration, fork, and TLDR identity changes.
3. Do not refactor production code beyond seams required by the tests.

Exit: current behavior has tests strong enough to detect migration regressions.

### Wave 1A — Contracts and reducer

Owner: ScribeKit contract agent.

Likely files: new files under `Sources/ScribeKit`, `ConfigLoader.swift`, and `Tests/ScribeKitTests`.

1. Add public values, tagged event coding, capabilities, errors, and service protocol.
2. Make the existing profile summary the single public Codable profile type.
3. Move transcript replay and event reduction from `SessionController` into ScribeKit.
4. Add deterministic transcript identity tests and Codable round-trip fixtures.
5. Add a fake service for workspace tests.

Exit: ScribeKit has no Chroma import; contract and reducer tests pass.

### Wave 1B — Explicit paths

Owner: ScribeKit runtime agent. May run in parallel with Wave 1A if it avoids the new contract files.

Likely files: `ScribePaths.swift`, `ConfigLoader.swift`, `ScribeSessionBootstrap.swift`, and persistence tests.

1. Add `ScribeRuntimeContext` and explicit config and bootstrap overloads.
2. Delegate existing environment-based APIs to explicit APIs.
3. Add two-home isolation tests.

Exit: explicit calls do not inspect environment or current directory.

### Wave 2 — Local service

Owner: ScribeKit local-service agent. Starts after both Wave 1 changes merge.

1. Implement the actor-owned local service and shared `AgentEvent` mapper.
2. Add a service contract test suite reusable against fake and local services.
3. Test list, create, open, submit, interrupt, rename, pin, and reconfigure.
4. Test concurrent different sessions and rejected overlapping turns.
5. Test persistence across service reconstruction.
6. Test fork and TLDR before moving those controls.

Exit: a new service instance can reopen and continue a session created by an old instance.

### Wave 3 — Workspace model

Owner: ScribeKit presentation-state agent.

1. Move session selection, grouping, and per-session state from `ScribeMacStore` and `SessionController`.
2. Implement queueing above the service and consume terminal events safely.
3. Port prompt history, unread activity, rename, pin, profile, fork, and TLDR actions.
4. Test entirely with the fake service, including service failures and malformed terminal sequences.

Exit: all transport-independent state is exercised without Chroma or filesystem access.

### Wave 4 — Blocks migration

Owner: ScribeBlocks agent.

1. Export `ScribeWorkspace` and narrow host hooks.
2. Convert blocks to shared model and value inputs.
3. Add headless renders for empty, loading, loaded, streaming reasoning and answer, tool running and completed, queued, interrupted, and failed states.
4. Retain focus, scroll, selection, and platform concerns outside the shared model.

Exit: reusable blocks consume only public ScribeKit presentation APIs.

### Wave 5 — Standalone migration

Owner: standalone app agent.

1. Construct the local service and workspace model in the macOS and Wayland shells.
2. Render `ScribeWorkspace` from both products.
3. Preserve app lifecycle, local directory selection, shell capture, profile recorder, and scene capture behavior.
4. Verify new, resume, switch, queue, interrupt, rename, pin, profile, fork, and TLDR behavior.
5. Delete superseded `ScribeMacStore` and `SessionController` behavior after parity tests pass.

Exit: both standalone products render `ScribeWorkspace`; no second replay, event, or queue reducer remains.

## Agent handoff rules

Every agent must:

- merge the immediately preceding wave before starting dependent work;
- preserve public contract fixtures unless intentionally versioning the protocol;
- list public API changes and deleted legacy paths in its change;
- add tests at the layer it changes instead of relying only on end-to-end tests;
- avoid unrelated formatting or package updates;
- leave the repository building and tests passing, or document an existing external blocker with the exact command and output.

Split work by the ownership boundaries above. Do not copy implementations between layers or leave temporary parallel implementations after a migration wave is complete.

## Validation

Run on every wave:

```text
swift build
swift test
```

Also run targeted ScribeKit or ScribeBlocks tests while iterating.

Required coverage:

- deterministic transcript replay identity;
- streamed reasoning, answers, and tool calls;
- exact-one terminal stream event;
- service failure and unexpectedly ended stream handling;
- queue, force-next, clear-queue, and interruption behavior;
- rename, clear-name, and pin updates;
- profile reconfiguration;
- fork and TLDR identity changes;
- persistence after local service reconstruction;
- concurrent turns in different sessions and `busy` rejection in one session;
- explicit-path isolation between temporary homes;
- headless workspace rendering with a fake service.

Before landing the standalone migration, build the macOS product on macOS and the Wayland product on Linux using the supported Swift build system.

## Completion criteria

- Existing macOS and Wayland Scribe are migrated in place and remain the primary production consumers.
- Both applications instantiate the same exported `ScribeWorkspace` and use `ScribeWorkspaceModel` with `LocalScribeSessionService`.
- Existing persisted sessions still list, open, replay, and continue without conversion.
- Current standalone features retain parity: new, resume, switch, queue, force-next, clear queue, interrupt, rename, clear name, pin, profile switching, fork, and TLDR.
- A headless process can construct `LocalScribeSessionService` with explicit paths and exercise session operations without importing Chroma or mutating environment/current directory.
- `ScribeKit` owns the transport-neutral contracts and presentation state without Chroma.
- `ScribeBlocks` contains reusable presentation without local runtime dependencies.
- One implementation owns transcript replay, streamed reduction, queue policy, interruption state, selection, and presentation updates.
- Sessions survive local service reconstruction.
- No parallel runtime, alternate persistence format, legacy standalone UI path, or duplicate transcript reducer remains.
