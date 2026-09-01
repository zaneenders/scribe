# Scribe Daemon Design

## Goal

`scribe-daemon` keeps chats and terminals alive when the GUI closes or disconnects.

- The GUI connects to the local daemon automatically.
- The GUI can switch to a remote daemon over SSH.
- Session messages and metadata are stored on the daemon host.
- A running agent continues while the daemon is alive.
- A terminal process continues while the daemon is alive.
- Sessions survive daemon restart; agents and terminals do not.
- The Slate TUI is deprecated. Setup commands move to `scribe-daemon`.

## Things the daemon owns

### Session

A session is the existing persisted Scribe chat. Its UUID is durable because it names data on disk.

```swift
typealias SessionID = UUID

struct Session: Codable, Sendable {
  let id: SessionID
  var name: String?
  var workingDirectory: String
  var profileName: String?
  var isPinned: Bool
  var createdAt: Date
  var lastMessageAt: Date?
}
```

The existing session files remain the source of truth for messages and metadata. This design does not introduce a second chat-storage format. In this document, **session** always means this durable chat; “history” means the messages inside it, not a second kind of object. `createdAt` and `lastMessageAt` expose the existing persisted conversation-recency fields; presentation-only changes do not modify either value. Root snapshots are sorted by `isPinned` first, then effective recency (`lastMessageAt ?? createdAt`) descending, with `SessionID` as the deterministic tie-breaker. A committed message updates `lastMessageAt` and emits a root session-updated event, so local and remote GUIs can maintain the same ordering without reading daemon-host files.

The persisted metadata schema gains `profileName`. New sessions store the selected profile name in addition to the existing resolved model and endpoint fields. On first discovery of legacy metadata without `profileName`, the daemon resolves it deterministically: it selects the unique configured profile whose resolved model and endpoint match the legacy values; if there is no unique match, it marks the session as requiring profile selection and does not open an agent until the user chooses an existing profile. Choosing a profile atomically persists `profileName` before the agent starts. A missing or renamed persisted profile is handled the same way and is never silently replaced by the current default. Metadata migration preserves the legacy resolved fields, timestamps, name, pin, and parent information. Discovery need not rewrite a legacy file merely to report it; the selected profile is written on the first successful explicit selection or other metadata mutation. The wire `profileName` is therefore nullable while migration is unresolved. Clients display an unresolved profile state and offer profile selection. `openAgent` fails with `profileRequired` until it is resolved. The root `selectSessionProfile` request resolves an unloaded or legacy session. `setProfile` changes an already-open agent's profile. Both operations persist the selected name before changing observable state and emit a root session-updated event; `setProfile` also updates `AgentSnapshot.profileName` and emits `profileChanged(name)` on the agent subscription. If persistence fails, the live profile and both event streams remain unchanged.

Protocol dates use canonical RFC 3339 UTC strings with fractional seconds. Decoders accept RFC 3339 values with or without fractional seconds for compatibility, while encoders always include milliseconds.

### Agent object

An agent object is the in-memory agent working on a session.

```swift
struct MessageCursor: Codable, Hashable, Sendable {
  let rawValue: String  // opaque to clients
}

struct AgentSnapshot: Codable, Sendable {
  let id: AgentID       // daemon-generation-scoped live object ID
  let sessionID: SessionID  // same durable ID as Session.id
  var profileName: String
  var state: AgentState
  var queueRevision: UInt64
  var queuedMessageCount: UInt32
  var latestMessageCursor: MessageCursor?
  var currentTurnID: UInt64?
  var eventSequence: UInt64
}

enum AgentState: String, Codable, Sendable {
  case idle
  case running
  case interrupting
  case failed
}
```

Internally, the existing `SessionHarness` owns the session document, persistence, model configuration, in-memory message queue, and running turn. It is not sent over the protocol. Queued messages are lost when the agent or daemon exits. Because queue contents are not bounded by a single protocol frame, `AgentSnapshot` contains only a count and revision. Clients fetch queue text through the paginated `queueSnapshot` request below. Queue admission has configurable per-message, per-agent count, and per-agent byte limits; an over-limit submission fails before mutation with `queueCapacityExceeded`.

Persisted messages have opaque, session-local `MessageCursor` values. Cursors are stable for the lifetime of the session and impose document order; clients must not derive them from array indexes or protocol event sequences. A non-`nil` `currentTurnID` identifies an unfinished turn whose accumulated content is fetched with the paginated `turnSnapshot(turnID, afterPart, limit)` request. This lets a reconnecting client reconstruct output produced so far without relying on transient text events or putting an unbounded turn into `AgentSnapshot`. When the turn is committed, normal message-history pagination is authoritative and `currentTurnID` becomes `nil`.

`SessionID` names the existing durable session UUID; it does not introduce a different wire representation. `AgentSnapshot.sessionID` is always the same value as `Session.id` for the session that agent has open. It is distinct from `AgentSnapshot.id`, which identifies only the daemon-generation-scoped live agent object.

Only one live agent and one client connection may own a session at a time. The daemon enforces this with an exclusive attachment, not merely a UI convention:

- The daemon keeps a `SessionID -> AgentID` map and an `AgentID -> connection` attachment map.
- `openAgent` checks and updates both maps as one daemon-isolated operation. If another connection owns the agent, it returns `sessionInUse`; it never creates a second `SessionHarness`.
- All mutating agent requests are accepted only from that attached connection and are processed serially by the agent runtime.
- Each attachment has a monotonically increasing ownership epoch. Every accepted mutation is stamped with that epoch and revalidates it immediately before execution. Detach, connection loss, and ownership transfer increment the epoch, so work queued by a former owner fails with `staleAttachment` rather than executing under the new owner.
- Detach or connection loss releases the attachment. It does not stop an in-flight turn or unload the agent. The first later `openAgent` attaches to that same live agent and receives its current state.
- Closing the agent explicitly stops its turn and unloads it, but leaves the durable session on disk.

A GUI that wants two views of one session must fan out one attachment inside that GUI; it cannot create two protocol attachments. Attachment ownership is tied to the transport connection, so a crashed or disconnected client cannot leave a timed stale lock. This prevents two machines from submitting, interrupting, changing profiles, or otherwise racing one session. `SessionHarness` remains the sole persistence writer.

The existing `fork` and `tldr` operations may change a `SessionHarness` from its parent session UUID to a newly persisted child UUID. That identity transition is one daemon-isolated transaction: after durable child creation succeeds, the daemon removes the parent `SessionID -> AgentID` entry, installs the child entry, updates the agent snapshot and summary, and emits the root session-created and agent-updated events before accepting another open or delete operation. The response includes the child `SessionID`. If child persistence fails, the harness and maps retain the parent identity and no success events are emitted. The durable parent session remains available and is no longer in use after a successful transition.

### Terminal object

A terminal object is a live PTY and shell process.

```swift
struct TerminalSnapshot: Codable, Sendable {
  let id: TerminalID    // daemon-generation-scoped live object ID
  var title: String?
  var workingDirectory: String
  var columns: UInt16  // canonical PTY width in character cells
  var rows: UInt16     // canonical PTY height in character cells
  var processState: TerminalProcessState
  var replayStartOffset: UInt64
  var nextOutputOffset: UInt64
}

enum TerminalProcessState: Codable, Sendable {
  case running
  case exited(status: Int32)
}

enum TerminalAccess: String, Codable, Sendable {
  case controller
  case observer
}

struct TerminalAttachmentSnapshot: Codable, Sendable {
  var terminal: TerminalSnapshot
  var access: TerminalAccess  // capability of this connection-local handle
}
```

The daemon owns the PTY file descriptor and child process. It retains a bounded amount of recent raw PTY output for reattachment. Terminal state is memory-only: the PTY, child process, dimensions, replay bytes, and terminal IDs disappear when the daemon exits. Nothing in `TerminalSnapshot` is written to the session files. Replay bytes are not embedded in JSON snapshots; they are transferred in bounded raw frames after an attachment baseline.

The dimensions matter because a PTY has a kernel window size. Shells and full-screen programs use it for wrapping and layout, and a resize updates the PTY with `TIOCSWINSZ` and causes `SIGWINCH`. The daemon keeps one canonical size so the process still has a defined window while no GUI is attached and a reconnecting GUI knows the size that produced the retained output. `UInt16` matches the PTY `winsize` fields; requests must reject zero or unsupported values. While attached, only the controlling client may resize it.

This is broadly how tmux works: a long-lived tmux server owns the PTYs, child processes, pane sizes, and scrollback in memory while clients attach and detach. Killing the tmux server (or rebooting the host) kills those live terminals. Tools such as tmux-resurrect can save commands and layouts, but they do not persist the original processes. Scribe's first version does not provide that kind of terminal restoration. Output positions are absolute byte offsets, not PTY read or protocol-frame numbers. On attachment, replay frames cover a suffix beginning at `replayStartOffset` and ending at `nextOutputOffset`.

The GUI continues to own `GhosttyTerminal`, which turns VT bytes into cells and render state. The daemon does not persist terminal emulator state and does not restore terminals after daemon exit.

Reattachment is best effort in the first version. A bounded suffix of VT output cannot always reconstruct a terminal exactly because it may depend on older cursor, screen, or mode changes. This is especially visible for long-running full-screen programs. When older output has been discarded, the GUI resets its emulator, replays the retained bytes, and indicates outside the PTY stream that earlier output and display state may be incomplete.

## Protocol objects

Durable and live identities intentionally use different types:

```swift
typealias SessionID = UUID    // persisted and stable across daemon restarts
typealias AgentID = UInt32    // in-memory, scoped to one daemon generation
typealias TerminalID = UInt32 // in-memory, scoped to one daemon generation
typealias ObjectID = UInt32   // in-memory, scoped to one connection

struct OperationID: Codable, Hashable, Sendable {
  let rawValue: UUID          // generated once by the client for a logical mutation
}
```

The daemon allocates live IDs and does not reuse one while it remains live. `AgentID` and `TerminalID` are stable across connections while the object and daemon generation remain alive, which allows a later connection to discover and attach to an existing object. A client nevertheless discards cached live IDs on every disconnect and reacquires them from a fresh root snapshot; only the reacquired values may be used. `ObjectID` is always scoped to one connection.

Each connection addresses attached objects with small `ObjectID` handles:

```text
object 0   daemon/root
object 1   attached agent
object 2   attached terminal
```

These object IDs are handles for one client connection. They are neither the durable session UUID nor the daemon-generation-scoped `AgentID` or `TerminalID`. Agents and terminals do not have UUIDs because they are never restored from disk.

- Detaching or disconnecting drops the handle only.
- Closing an agent stops that live agent but keeps its session.
- Terminating a terminal process kills its child but retains the terminal object for inspection.
- Closing a terminal removes the live object and its replay; closing a running terminal first terminates its child.
- Deleting a session removes durable chat data.

## API

### Root object: object `0`

```swift
struct AgentSummary: Codable, Sendable {
  let id: AgentID
  let sessionID: SessionID
  var state: AgentState
}

struct TerminalSummary: Codable, Sendable {
  let id: TerminalID
  var title: String?
  var workingDirectory: String
  var columns: UInt16
  var rows: UInt16
  var processState: TerminalProcessState
  var replayStartOffset: UInt64
  var nextOutputOffset: UInt64
}

struct DaemonSnapshot: Codable, Sendable {
  var sessions: [Session]
  var agents: [AgentSummary]
  var terminals: [TerminalSummary]
  var eventSequence: UInt64
}

struct RootSnapshotPage: Codable, Sendable {
  var sessions: [Session]
  var agents: [AgentSummary]
  var terminals: [TerminalSummary]
  var eventSequence: UInt64
  var nextCursor: RootSnapshotCursor?
}

struct CursorMessage: Codable, Sendable {
  var cursor: MessageCursor
  var message: ScribeMessage
}

struct MessagePage: Codable, Sendable {
  var messages: [CursorMessage]
  var olderCursor: MessageCursor?
  var newerCursor: MessageCursor?
  var hasOlder: Bool
  var hasNewer: Bool
}

struct QueuedMessage: Codable, Sendable {
  var number: UInt64
  var text: String
}

struct QueueSnapshotPage: Codable, Sendable {
  var revision: UInt64
  var messages: [QueuedMessage]
  var nextNumber: UInt64?
}

struct NumberedTurnPart: Codable, Sendable {
  var number: UInt64
  var part: AgentTurnPart  // versioned wire union for text, reasoning, tool, or image content
}

struct TurnSnapshotPage: Codable, Sendable {
  var turnID: UInt64
  var parts: [NumberedTurnPart]
  var nextPart: UInt64?
}
```

Root requests:

```text
snapshot(cursor: RootSnapshotCursor?, limit: UInt32)
createSession(workingDirectory, profileName, operationID: OperationID)
updateSession(sessionID: SessionID, patch: SessionPatch, operationID: OperationID)
selectSessionProfile(sessionID: SessionID, profileName: String, operationID: OperationID)
openAgent(sessionID: SessionID, newObjectID: ObjectID)
deleteSession(sessionID: SessionID, operationID: OperationID)
createTerminal(workingDirectory, columns, rows, newObjectID: ObjectID, operationID: OperationID)
attachTerminal(terminalID: TerminalID, newObjectID: ObjectID)
operationResult(operationID: OperationID)
```

A root snapshot is a complete, point-in-time protocol state, not a screenshot or a separate persisted copy. It contains bounded summaries, never message bodies or terminal replay bytes, and populates and resynchronizes the session list and live-object list after connect. `AgentSummary` and `TerminalSummary` contain identity and list-display metadata only. The non-paginated `DaemonSnapshot` is the logical aggregate; each `RootSnapshotPage` contains slices directly so it cannot be mistaken for a complete snapshot. Large root snapshots return `RootSnapshotPage` values and are paginated with an opaque `RootSnapshotCursor`: the first page freezes a logical baseline through event sequence `N`, later pages use its cursor, and each page respects `limit` and the negotiated frame size. A page may contain slices of any of the three arrays; clients append each array independently in page order. Every page repeats the same `eventSequence`, and `nextCursor == nil` is the only indication that the snapshot is complete—a short page does not imply completion. Cursors have a short bounded lifetime; expiration returns `snapshotExpired` and the client discards every accumulated array and restarts from the first page. Object snapshots provide the baseline to which later events are applied. `openAgent` binds the supplied protocol object ID and returns the initial `AgentSnapshot` atomically. `createTerminal` and `attachTerminal` bind the handle and return its initial `TerminalAttachmentSnapshot` atomically. A separate initial object `snapshot` call is therefore unnecessary. A client-selected `newObjectID` must be nonzero and unbound on that connection. Reusing a bound ID fails with `objectIDInUse`; IDs released by normal detach or object closure may be reused only after the client has observed that closure. The terminal recovery operation described below is the sole atomic replacement exception: it takes a fresh ID, installs the new baseline, and then closes the invalidated old handle.

Root events report session and live-object creation, update, and removal. Each event carries a monotonically increasing root `eventSequence`. Snapshot capture and event subscription are one daemon-isolated operation: events after `N` are buffered in the connection's normal bounded queue while all pages are fetched, and released after the final page. The first later event is `N + 1`. A duplicate sequence is ignored; a higher-than-expected sequence is a gap and requires a fresh root snapshot. Sequence history need not be retained because the snapshot is the recovery mechanism.

Root buffering is bounded, including while paginated snapshot pages are outstanding. If it overflows, the daemon invalidates the root subscription, discards its queued data events, and sends `subscriptionInvalidated(scope: root)` through the reserved control lane. No later root events are sent until the client starts a new snapshot. If the invalidation notice cannot be queued, the daemon closes the connection. A cursor from an invalidated snapshot returns `snapshotInvalidated`; the client discards all of its pages and starts again.

`createSession` validates that the working directory is an absolute path on the daemon host and that the named profile exists, persists both values, and returns the created `Session`. `updateSession` changes only the supplied presentation fields, preserves conversation recency, returns the updated `Session`, and emits a root session-updated event. Its wire payload uses a patch object: an omitted `name` leaves the name unchanged, a JSON `null` clears it, and a string replaces it; an omitted `isPinned` leaves the flag unchanged, and a Boolean replaces it. Implementations must use presence-aware custom decoding rather than synthesized `Optional` decoding, which conflates an omitted key with `null`.

```swift
struct SessionPatch: Codable, Sendable {
  // Wire semantics, not ordinary Swift Optional semantics:
  var name: Presence<String?>
  var isPinned: Presence<Bool>
}

enum Presence<Value: Codable & Sendable>: Codable, Sendable {
  case omitted
  case value(Value)
}
```

`Presence` is a protocol-modeling type: its enclosing `SessionPatch` decoder checks `container.contains(_:)`; for `name`, a present JSON `null` becomes `.value(nil)`. Encoders omit `.omitted` keys. `selectSessionProfile` validates the named profile, atomically persists it without changing conversation recency, returns the updated `Session`, and emits a root session-updated event. It fails with `sessionInUse` when a live agent owns the session; an attached owner uses agent `setProfile` instead. `deleteSession` fails with `sessionInUse` while a live agent exists for the session. Closing that agent through its attached object is required first. Root requests cannot close agents or terminate terminals by daemon-generation-scoped ID; destructive live-object operations require an authorized attachment.

### Agent object

Agent requests:

```text
snapshot
messages(after: MessageCursor?, before: MessageCursor?, limit: UInt32)
queueSnapshot(revision: UInt64?, afterNumber: UInt64?, limit: UInt32)
turnSnapshot(turnID: UInt64, afterPart: UInt64?, limit: UInt32)
submit(text, operationID: OperationID)
interrupt(operationID: OperationID)
clearQueue(operationID: OperationID)
sendQueued(strategy, operationID: OperationID)
setProfile(name, operationID: OperationID)
fork(boundary, operationID: OperationID)
tldr(startBoundary, endBoundary, operationID: OperationID)
close(operationID: OperationID)
```

```swift
enum QueueDrainStrategy: String, Codable, Sendable {
  case next
  case all
}
```

`sendQueued(strategy:)` force-sends either the oldest queued message or all queued messages as the next turn (matching the existing `QueueMode.all` drain behavior). If a turn is running, the agent interrupts it first and sends after that turn has finished cleanly. The name is `sendQueued`, rather than `sendNext`, because the `.all` strategy may consume more than the next item. Automatic queue draining uses the same strategy type.

Agent events:

```text
stateChanged
userMessage
assistantSectionStarted
assistantText
assistantFinished
toolStarted
toolFinished
queueChanged(revision, queuedMessageCount)
profileChanged(name)
usageChanged
turnFinished
```

The wire events are stable client-facing messages. The existing internal `AgentEvent` enum is not serialized directly. Each agent event carries a monotonically increasing, agent-local `eventSequence`.

`messages` returns a `MessagePage` containing persisted messages in document order and their opaque cursors. Omitting both request cursors returns the newest page; supplying both is invalid. `after` and `before` are exclusive boundaries: the message named by the supplied cursor is not repeated. `hasOlder` and `hasNewer`, not the number of returned items, indicate whether another request in either direction can produce data, and the corresponding cursor is non-`nil` whenever that flag is true. `queueSnapshot` freezes one queue revision; omitting `revision` starts at the current revision, while subsequent pages repeat that revision and use `afterNumber` as an exclusive boundary. `nextNumber == nil` alone means the queue snapshot is complete. If the queue mutates before paging completes, the continuation fails with `snapshotInvalidated` and the client restarts from the latest revision. `turnSnapshot` returns a `TurnSnapshotPage` with ordered, numbered parts of the unfinished turn. `afterPart` is exclusive, while a non-`nil` `nextPart` is the part number to supply as `afterPart` for the next page; `nextPart == nil` is the only indication that the page is complete. Continuations are scoped to the captured session, queue, or turn and fail with `snapshotInvalidated` if that source is replaced while paging. Responses must fit the negotiated frame size; the daemon may return fewer than `limit` items and a single message, queued message, turn part, or tool payload that cannot fit is returned through chunked message-content frames. Page envelopes themselves are bounded independently of chunked fields. A newly attached GUI loads history and queue contents through these APIs rather than reading daemon-host files. Supplying `afterNumber` without `revision` is invalid, and page numbers are scoped to their queue revision rather than being durable queue-entry IDs.

Agent snapshot capture and event subscription are atomic. If the snapshot is through sequence `N`, subsequent events begin at `N + 1`. On a gap, the client requests a fresh snapshot, reloads queue contents when its revision changed, reconciles persisted history from `latestMessageCursor`, and replaces any partial rendering from the paginated `currentTurnID` snapshot. Agent event sequences are transient and restart with a new live agent; message cursors are the durable history boundary. `close` is accepted only on the attached agent object, stops its turn, unloads it, and preserves the durable session.

Agent event and snapshot-pagination buffering is bounded. Overflow invalidates that handle's subscription, drops queued data events, and sends `subscriptionInvalidated(scope: agent, latestMessageCursor, queueRevision, currentTurnID)` through the reserved control lane; no later agent events are sent on the invalidated handle. If the notice cannot be queued, the daemon closes the entire connection: silently removing a multiplexed handle would not be observable to an idle client. Recovery uses the attached object's `snapshot`, followed by `messages`, `queueSnapshot`, and, when present, `turnSnapshot`; the running turn is not interrupted. Requests using continuations from an invalidated snapshot return `snapshotInvalidated`.

### Common attached-object lifecycle

```text
detach
```

`detach` is sent to an attached agent or terminal object. It removes only that connection's handle, event subscription, and queued outbound data; it does not close the agent, delete the session, terminate the terminal process, or remove the terminal object. Explicit detach is needed when a tab closes but the shared daemon connection remains open. Otherwise those resources are also released automatically when the connection closes. Putting `detach` on the target object avoids a root-level `detachObject(objectID)` bookkeeping API.

Every server-initiated handle removal is reported through the reserved control lane as `objectClosed(objectID, reason)`. This includes an explicit object `close` affecting other handles, terminal retention expiry, and runtime failure; client-initiated `detach` and connection loss need no such event. The event is the point after which that client may reuse the `ObjectID`. For terminal closure, all promised replay/output and any `exited` event precede `objectClosed`; the root removal event follows it. The connection writer enforces this ordering across the reserved control and normal data lanes: a later control-lane frame may not overtake prerequisite data frames, even though unrelated control traffic may bypass queued data. For a connection that requested `close`, the success response precedes its `objectClosed`, so the response can still be correlated. If an `objectClosed` event cannot be queued, the daemon closes the connection rather than silently removing a multiplexed handle.

### Terminal object

Terminal requests:

```text
snapshot
input(bytes, operationID: OperationID)
resize(columns, rows, operationID: OperationID)
terminateProcess(operationID: OperationID)
close(operationID: OperationID)
```

Terminal events:

```text
replay(offset, bytes)
output(offset, bytes)
resized(columns, rows)
accessChanged(access)
replayInvalidated(availableFromOffset, nextOutputOffset)
exited(status)
```

The attached-object `snapshot` request returns a `TerminalAttachmentSnapshot`, including the requesting handle's current access. Terminal replay, input, and output payloads are raw bytes, not JSON or base64. An `input` request payload starts with the `OperationID` UUID as 16 bytes in RFC 4122 network byte order, followed by zero or more PTY input bytes. The frame's payload length therefore must be at least 16; those first 16 bytes are metadata and are not written to the PTY. JSON representations of `OperationID` use the canonical hyphenated UUID string. An output or replay event payload starts with an eight-byte, big-endian `UInt64` offset followed by the bytes. The offset is the absolute position of the first byte. The next expected offset is `offset + bytes.count`. Byte payloads are split so every complete frame is at most the negotiated maximum frame size; PTY read boundaries have no protocol meaning.

### Terminal stream behavior

The PTY read path never waits for a GUI or socket write. For every read, the terminal object assigns offsets, appends the bytes to its shared replay buffer, and enqueues output independently for each attached connection. Socket writes preserve output order for each terminal.

Attaching is atomic with respect to output. While isolated with the terminal runtime, the daemon captures `N`, chooses a contiguous retained suffix `R'..<N` that fits the attachment's bounded replay allocation, and transfers ownership of references to those immutable replay segments into the attachment queue before publishing the handle. The returned `TerminalAttachmentSnapshot` reports `replayStartOffset = R'`, not an earlier range that might disappear in flight, and includes that handle's controller or observer access. The response contains metadata only and is followed by raw `replay` frames covering exactly `R'..<N`, then live `output` frames beginning at `N`. Global replay eviction cannot remove the attachment-owned segments; their memory is charged to that connection until sent or invalidated. Output produced after capture is queued behind replay, so no byte can slip between replay and live output. If the daemon cannot reserve enough queue capacity even for its configured minimum replay baseline, attachment fails with retryable `attachmentCapacityExceeded` before binding the handle. Later live-output pressure follows the invalidation rules below. All frames obey the negotiated maximum size.

A client initializes its next expected byte offset from the first replay frame (or `N` when replay is empty), then tracks it across replay and live output:

- An equal offset is the next byte range.
- A lower offset is duplicate output and is trimmed or ignored.
- A higher offset is a gap and requires a fresh attachment baseline.

Each connection has a bounded outbound data queue plus a reserved, bounded control lane. A slow client must not stall the PTY or other clients. When a client falls behind, the daemon drops that terminal handle's queued output and sends `replayInvalidated` through the control lane. No later output is sent on that invalidated handle. If the control notice cannot be queued, the daemon closes the entire connection; silently removing a multiplexed handle would not be observable to an idle client.

Recovery uses `attachTerminal` with a fresh, unused `ObjectID`. The operation atomically replaces any invalidated handle for that terminal on the same connection and establishes a new snapshot/replay/live-output baseline. The old handle is closed after the new baseline is installed. If the retained range no longer includes the missing bytes, the GUI performs the best-effort reset and replay described above.

In the first version, only one attached client may send input, resize, `terminateProcess`, or `close` on a terminal. Other attachments are observers. The first attachment is the controller; control transfers after it detaches or disconnects, and every remaining handle receives `accessChanged` when its capability changes. This avoids interleaved input and competing window sizes. A later protocol version can add explicit control acquisition if needed. Root snapshots expose no capability that bypasses this check.

Terminal control uses the same ownership-epoch rule as agents. Input and destructive requests accepted under an old controller epoch are rejected with `staleAttachment` if control transfers before they execute. Output delivery is unaffected.

The daemon emits all final readable PTY output before `exited`. `terminateProcess` begins a bounded asynchronous shutdown of the process group and retains the exited terminal, replay, and status for inspection. Shutdown first sends the platform's graceful termination signal, continues draining PTY output for a configured grace period, escalates to `SIGKILL`, and then drains until EOF or a second bounded deadline. Descendants retaining the slave PTY therefore cannot block cleanup forever. `terminateProcess` and `close` responses acknowledge that shutdown was accepted; exit and root-removal events report completion. `close` marks the terminal as closing immediately, rejects later requests, and removes the terminal object, replay, and all handles after bounded shutdown. If a final drain deadline expires, removal proceeds and the protocol does not promise output beyond the last emitted offset. Exited terminals otherwise remain attachable until `close` or the daemon's retention policy removes them.

Every terminal process group and agent tool-process group is launched through a small independently packaged process-reaper helper before user code can run. The helper is the direct parent of the group leader and receives a daemon-liveness pipe whose write end is held only by the daemon and is never inherited by launched children. On orderly removal the daemon asks the helper to perform the same bounded graceful-then-forceful shutdown and waits for acknowledgement. On daemon exit, crash, or `SIGKILL`, EOF on the liveness pipe makes the helper immediately kill the registered process group and reap its child. The helper creates the process group itself and acknowledges it to the daemon only after containment is installed; the daemon does not expose or drive the child before that acknowledgement, preventing a crash window that could create an untracked process. The helper records process identity at spawn and never acts on a recycled PID. Platform-specific implementations may use stronger primitives such as Linux parent-death signals, but closing a PTY master or relying on `SIGHUP` alone is insufficient. Crash tests run descendants that ignore `SIGHUP`, fork, and retain the slave PTY, then verify that no process remains after daemon death. A machine-wide power loss naturally ends the processes; sessions remain recoverable from disk.

## Connections

### Local

```text
GUI -> ~/.scribe/run/daemon.sock -> scribe-daemon
```

On launch, the GUI connects locally. If the socket is unavailable, it starts `scribe-daemon serve` and retries.

Exactly one daemon may serve a Scribe data directory. Before publishing the socket, `serve` atomically acquires a per-data-directory process lock and holds it for its lifetime. Socket probing, stale-socket removal, and publication happen only while holding that lock. A second daemon that loses the race connects to or waits for the winner to publish its socket and then exits successfully; it never starts runtimes or opens session files. Recovery verifies that stale lock and socket artifacts belong to the current user before removing them. Concurrent-launch, daemon-crash, and stale-socket tests enforce this invariant. This process-level exclusion is required for the `SessionHarness` sole-writer guarantee; the in-memory attachment maps alone are insufficient.

The local socket is an authorization boundary because a connected peer can read chats and control live processes. `~/.scribe/run` must be a real, current-user-owned directory with mode `0700`; the daemon refuses symlinks, unsafe ownership, and permissive modes rather than falling back to an insecure location. It creates the socket under a restrictive umask, sets mode `0600`, and verifies peer credentials identify the current user on platforms that expose them. Existing lock or socket files owned by another user are never followed, replaced, or removed.

### Remote over SSH

```text
GUI -> NIOSSH -> remote sshd
                 -> scribe-daemon bridge --start-if-needed
                 -> ~/.scribe/run/daemon.sock
                 -> scribe-daemon
```

The bridge only relays protocol bytes. It does not own chats, agents, or terminals. Losing SSH stops the bridge but not the daemon.

A saved remote daemon contains a display name and OpenSSH host alias. A focused Swift parser reads `~/.ssh/config`; NIOSSH uses the resolved host, user, port, keys, jump host, and known-host policy.

Initially, the remote daemon is installed manually at:

```text
~/.scribe/bin/scribe-daemon
```

SSH behavior is tested end to end against disposable OpenSSH servers with generated keys, including authentication, host-key rejection, bridge startup, disconnect, and reconnect.

## Frame format

The Unix socket and SSH channel carry the same frame:

```swift
struct FrameHeader {
  var version: UInt16
  var code: UInt16
  var objectID: ObjectID
  var requestID: UInt32
  var payloadLength: UInt32
}
```

The 16-byte header uses big-endian integers.

- `version` is the selected protocol version after the handshake; hello request and response frames use bootstrap version `0`.
- `code` identifies the request, response, or event.
- `objectID` identifies the target protocol object.
- `requestID` correlates a request and response; events use zero.
- `payloadLength` is the number of bytes after the header.

Control payloads use JSON encoded with `Codable`. Terminal and chunked message-content byte messages use raw payloads. `maximumFrameSize` includes the 16-byte header. Every decoder rejects a header whose payload length would exceed the negotiated limit before allocating payload storage. Collection responses are paginated or contain bounded summaries; large byte content is split into ordered raw frames.

JSON is a specified wire format rather than Swift's synthesized representation. Every wire union uses a custom adjacent-tag encoding with a required `type` string and case-specific fields—for example `TerminalProcessState.exited(status: 0)` is `{"type":"exited","status":0}` and `OperationQueryResult.inProgress` is `{"type":"inProgress","retryAfterMilliseconds":...}`. Unit-like cases still encode as objects containing `type`. Unknown tags are rejected as an unsupported value for that protocol version. `Presence` is never encoded as a standalone enum: its enclosing patch omits `.omitted` and encodes `.value` as the field's ordinary JSON value. Fields eligible for chunking use a schema-defined adjacent union of `{"type":"inline","value":...}` or `{"type":"chunked","reference":...}`; a decoder never guesses from an object's shape. Each protocol version publishes exact JSON schemas and golden fixtures for requests, successes, errors, events, every union case, and chunk references. Implementations use custom `Codable` conformances and do not make synthesized associated-value-enum encoding part of the contract.

### Chunked message content

A schema-defined chunkable field encodes inline while it fits one frame; otherwise its `chunked` union case contains a `ChunkedContentReference`:

```swift
struct ChunkedContentReference: Codable, Sendable {
  let transferID: UInt64       // unique for the lifetime of this connection
  let field: String            // stable semantic field name
  let byteLength: UInt64
  let encoding: ContentEncoding
}

enum ContentEncoding: String, Codable, Sendable {
  case utf8
  case binary
}
```

The descriptor is followed by one or more raw `contentChunk` frames. Their payload begins with this 28-byte big-endian header and continues with chunk bytes:

```text
transferID  UInt64
byteOffset  UInt64
byteLength  UInt64   // total length, repeated in every chunk
flags       UInt16   // bit 0 is final; all other bits must be zero
reserved    UInt16   // must be zero
bytes       ...
```

Chunks for one transfer are emitted in increasing contiguous `byteOffset` order starting at zero. The final flag is set exactly when `byteOffset + bytes.count == byteLength`; a zero-length value stays in JSON and is never chunked. Different transfers and request IDs may interleave, so receivers reassemble by `transferID`, while the frame's `requestID` associates response chunks with the request that produced their descriptor. Event chunks use request ID zero and rely on the connection-unique transfer ID. A transfer is valid only after its descriptor has been received, its encoding and semantic field come from that descriptor, and duplicate, overlapping, out-of-range, mismatched-length, or unknown-transfer chunks are protocol errors. A response is complete only after its JSON descriptor and all referenced transfers complete. Connection or subscription closure abandons incomplete transfers.

This mechanism applies independently to message text, reasoning, image content, tool arguments and results, and unfinished-turn parts. Stable numeric `code` values distinguish `contentChunk` from terminal `replay`, `output`, and `input`, so their raw layouts are never inferred from context.

Chunking bounds frames, not aggregate receiver memory, so each protocol version also defines limits for one transfer's `byteLength`, concurrent incomplete transfers, and aggregate incomplete-transfer bytes per connection. The receiver validates those limits and overflow-checks every `byteOffset + bytes.count` before reserving storage or accepting a chunk. Large accepted transfers stream incrementally to their typed consumer or bounded temporary storage; implementations must not allocate a contiguous buffer merely because the descriptor advertises its size. Incomplete transfers have a bounded idle timeout. Exceeding a transfer limit, timeout, or malformed chunk is a protocol error that abandons all incomplete transfers and closes the connection.

### Request and error semantics

Every valid request has a nonzero `requestID`, and at most one request with that ID may be outstanding on a connection. Reuse while outstanding, a request with ID zero, a response with no matching request, or an event with a nonzero request ID is a protocol error and closes the connection. Each accepted request receives exactly one terminal JSON success or error response; raw content chunks are part of that response and do not constitute additional terminal responses.

Every state-changing request carries an `OperationID`, generated once and reused only when retrying that same logical mutation. Read-only requests, attachment, and detach do not need one. The daemon records an operation's in-progress state before beginning its effects and records its terminal success or error before answering its callers. A duplicate with the same opcode, target live identity, and canonical arguments joins the in-progress operation or returns the cached result without executing again; reuse with different inputs returns `operationIDConflict`. For large arguments such as terminal input, a record may retain a collision-resistant digest plus the canonical argument length instead of retaining the bytes, but it must still detect conflicting reuse. Results that establish a handle retain the durable or live identity and require a fresh attach after reconnect rather than recreating the old connection-local `ObjectID`.

```swift
enum OperationQueryResult: Codable, Sendable {
  case inProgress(retryAfterMilliseconds: UInt32?)
  case completed(OperationTerminalResult)
  case unknown
}
```

`operationResult` returns this union without recreating a connection-local handle. `completed` contains the same typed success or error information as the original terminal response. For `inProgress`, the client may poll after the optional delay or resend the identical request with the same `OperationID` to join it; it must not create a new ID. `unknown` means the daemon cannot safely determine whether the mutation occurred.

Operation retention is bounded, but every admitted operation's in-progress record and terminal result remain queryable for the entire `operationRetryWindowSeconds` advertised in `ServerHello`, measured from terminal completion; in-progress records do not expire. The daemon must reserve record capacity before applying any effects. If it cannot honor the window, it rejects the new mutation without executing it using `operationCapacityExceeded` and may include a retry delay. It never evicts an unexpired record. Per-connection admission and rate limits bound outstanding mutations, and terminal clients batch adjacent keystrokes and paste bytes into reasonably sized input operations rather than assigning an operation to each byte. Retained terminal-input records need only keep the argument digest, length, target identity, and terminal result, not the input bytes. The advertised window is a minimum guarantee: records may remain queryable longer, but clients must not depend on that.

If a connection is lost before a mutation response arrives, the client first reconnects and queries `operationResult`. On `completed`, it consumes the cached result. On `inProgress`, it polls or rejoins with the identical operation and ID. On `unknown`—including after daemon restart—it reconciles durable effects through root and message snapshots and surfaces any still-ambiguous action to the user. It must never automatically issue the mutation under a new ID. In particular, `submit`, queue draining, `fork`, and `tldr` are not blindly retried. A successful fork or tldr result retains the child `SessionID`, so loss of its original response remains correlatable while the daemon generation survives.

Errors use a common envelope containing a stable machine-readable code, a human-readable message, and optional versioned details. Expected state and validation failures—including `sessionInUse`, `profileRequired`, `queueCapacityExceeded`, `attachmentCapacityExceeded`, `staleAttachment`, `snapshotExpired`, `snapshotInvalidated`, `objectIDInUse`, `operationIDConflict`, `operationCapacityExceeded`, `unknownObject`, `wrongObjectType`, invalid arguments, and unsupported operations—fail only that request. Unknown object IDs receive `unknownObject`, including requests sent after the client has observed handle closure. Unsupported numeric opcodes, malformed JSON, invalid raw layouts, impossible response correlation, and other framing violations are protocol errors and close the connection after a bounded error response when one can be sent safely. Exact numeric opcode and error-code assignments remain to be selected, but these semantics are part of version 1.

## Handshake

The first request is `hello` on object `0`. The frame header for both `ClientHello` and its success or error response uses the reserved bootstrap version `0`; no other frame may use version `0`. The server reads only the bounded hello frame, selects the highest version in the intersection of the advertised range and its supported range, and returns `ServerHello` in a version-0 frame. All subsequent frames use `selectedVersion`. An empty version intersection returns `unsupportedVersion` in a version-0 response and then closes the connection.

```swift
struct ClientHello: Codable, Sendable {
  var minimumVersion: UInt16
  var maximumVersion: UInt16
  var clientVersion: String
  var maximumFrameSize: UInt32
}

struct ServerHello: Codable, Sendable {
  var selectedVersion: UInt16
  var daemonVersion: String
  var maximumFrameSize: UInt32
  var operationRetryWindowSeconds: UInt32
}
```

The client must advertise `minimumVersion > 0`, `minimumVersion <= maximumVersion`, and `maximumFrameSize` at least the protocol's fixed minimum frame size. Version 1 uses a minimum of 4 KiB, which is also the server's maximum accepted bootstrap-frame size. The negotiated frame size is the smaller of the client's value and the server's configured limit and must still meet that selected version's minimum. `operationRetryWindowSeconds` is nonzero and advertises the minimum completed-operation retention guarantee described above. Invalid ranges or sizes receive `invalidHello` and the connection closes. Before hello completes, the decoder caps the frame at the bootstrap limit; afterward it applies the negotiated limit before allocating payload storage.

Every successful connection starts a new `ObjectID` namespace, but `AgentID` and `TerminalID` remain scoped to the daemon generation. On disconnect, the GUI discards cached agent IDs, terminal IDs, protocol handles, and transient event positions; it obtains fresh values from snapshots after reconnecting. Reacquired live IDs may be numerically unchanged if the daemon and objects survived, but clients must not depend on that. Durable session UUIDs and message cursors may be retained. This avoids giving an in-memory daemon instance a UUID or persisting a generation counter solely to detect improbable numeric reuse.

## Daemon commands

```text
scribe-daemon serve
scribe-daemon bridge --start-if-needed
scribe-daemon status
scribe-daemon stop
scribe-daemon config ...
scribe-daemon auth codex
scribe-daemon auth logout codex
```

For remote Codex login, NIOSSH forwards callback port `1455` and the authorization URL opens on the GUI machine.

## Refactor before networking

The daemon boundary should first exist as an in-process ownership boundary. The GUI currently wires `PTYSession` directly to `GhosttyTerminal` in `SessionTerminal`. Refactor that path to use the same terminal runtime and attachment interface that the daemon will eventually expose. The first implementation remains in-process: it opens no sockets, starts no daemon, and has no reconnect behavior caused by networking.

SwiftNIO's `ByteBuffer` is the lowest byte-storage abstraction for the new runtime and protocol code. PTY output, replay segments, terminal input, and later frame encoders use `ByteBuffer`; conversions to `Data` only occur at existing UI or `Codable` compatibility boundaries. Runtime types must not depend on a channel, event loop, Unix socket, or SSH, so tests and the in-process adapter can use them without networking.

The in-process terminal path has the same layers as the eventual split:

```text
PTYSession
  -> TerminalRuntime (process, offsets, replay, attachments)
  -> InProcessTerminalClient
  -> GhosttyTerminal
```

The networked path later replaces only the adapter:

```text
PTYSession
  -> TerminalRuntime
  -> daemon protocol over NIO ByteBuffer
  -> NetworkTerminalClient
  -> GhosttyTerminal
```

`TerminalRuntime` owns the PTY, canonical size, process state, next output offset, and replay buffer. An attachment receives an initial replay range and then ordered output events. The in-process client must consume that API rather than reaching through to the PTY. This exercises ownership and stream semantics before transport concerns are introduced.

The same approach applies to chat after the terminal shape is proven: put `SessionHarness` behind a runtime object and make the current GUI call an in-process client facade before serializing that facade over a daemon connection.

## Merge plan

The work should land in independently testable pieces, with the current GUI remaining functional after each piece.

1. **ByteBuffer terminal primitives.** Add a bounded segmented replay buffer with absolute `UInt64` offsets and tests for append, eviction, slicing, and offset overflow. Add `NIOCore` only to the target that owns these primitives. No PTY or GUI changes are required.
2. **In-process terminal runtime.** Put `PTYSession` behind `TerminalRuntime`; add attachments, ordered output and exit events, input, resize, and process state. Adapt `SessionTerminal` to use an `InProcessTerminalClient` while retaining `GhosttyTerminal` in the GUI. This is the main architecture refactor and still has no networking.
3. **Runtime lifecycle and pressure.** Add bounded attachment queues, slow-consumer invalidation, controller versus observer behavior, cleanup, and real-PTY integration tests. In-process tests should deliberately pause a consumer and verify that the PTY and other consumers continue.
4. **Protocol library.** Add frame encoding and incremental decoding directly over `ByteBuffer`, handshake messages, typed IDs, stable error responses, frame-size limits, and embedded-channel or in-memory tests. This piece starts no daemon and opens no sockets.
5. **Local daemon transport.** Add `scribe-daemon serve`, per-data-directory singleton locking, secure Unix socket lifecycle and peer authorization, and map one connection onto the already-tested terminal runtime. Add the process-reaper helper and concurrent startup, stale-artifact recovery, create, attach, input, resize, bounded process termination, daemon-crash cleanup, and object close integration tests. Chat support is not required here.
6. **Network terminal client.** Add a client adapter with the same interface as `InProcessTerminalClient`, then switch the GUI composition root from the in-process adapter to the local daemon. The terminal view and `GhosttyTerminal` should not need another ownership refactor.
7. **Chat runtime and protocol.** Move session discovery and `SessionHarness` ownership behind an in-process facade first, then add chat snapshots, event cursors, and protocol mapping. This needs a separate detailed reconnect design before implementation.
8. **SSH transport.** Add the byte-only bridge and NIOSSH client after the local protocol is stable. The bridge does not get separate daemon semantics.
9. **Setup and cleanup.** Move setup/auth commands, remove deprecated Slate entry points, and add packaging and upgrade behavior.

For the first terminal-runtime implementation, use a configurable bounded replay buffer with a conservative default such as 16 MiB per terminal. Also enforce a daemon-wide limit so many terminals cannot consume unbounded memory. The exact defaults can change without changing the protocol because snapshots expose the retained offset range.

## Remaining decisions

1. When should an idle agent be unloaded?
2. What numeric opcodes map to the API above?
3. How long should exited terminal objects remain available?
4. What per-connection and daemon-wide memory limits should ship as defaults?
