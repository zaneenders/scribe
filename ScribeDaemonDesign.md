# Scribe Daemon Design

## Goal

`scribe-daemon` keeps chats and terminals alive when the GUI closes or disconnects.

- The GUI connects to the local daemon automatically.
- The GUI can switch to a remote daemon over SSH.
- Session messages and metadata are stored on the daemon host.
- A running agent continues while the daemon is alive.
- A terminal process continues while the daemon is alive.
- Sessions survive daemon restart; agents and terminals do not.
- The Slate TUI are deprecated. Setup commands move to `scribe-daemon`.

## Things the daemon owns

### Session

A session is the existing persisted Scribe chat. Its UUID is durable because it names data on disk.

```swift
typealias SessionID = UUID

struct Session: Codable, Sendable {
  let id: SessionID
  var name: String?
  var workingDirectory: String
  var profileName: String
  var isPinned: Bool
}
```

The existing session files remain the source of truth for messages and metadata. This design does not introduce a second chat-storage format. In this document, **session** always means this durable chat; “history” means the messages inside it, not a second kind of object.

### Agent object

An agent object is the in-memory agent working on a session.

```swift
struct MessageCursor: Codable, Hashable, Sendable {
  let rawValue: String  // opaque to clients
}

struct AgentSnapshot: Codable, Sendable {
  let id: AgentID       // daemon-generation-scoped live object ID
  let sessionID: SessionID  // same durable ID as Session.id
  var state: AgentState
  var queuedMessages: [String]
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

Internally, the existing `SessionHarness` owns the session document, persistence, model configuration, in-memory message queue, and running turn. It is not sent over the protocol. Queued messages are lost when the agent or daemon exits.

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
```

Root requests:

```text
snapshot(cursor: RootSnapshotCursor?, limit: UInt32)
createSession
openAgent(sessionID: SessionID, newObjectID: ObjectID)
deleteSession(sessionID: SessionID)
createTerminal(workingDirectory, columns, rows, newObjectID: ObjectID)
attachTerminal(terminalID: TerminalID, newObjectID: ObjectID)
```

A root snapshot is a complete, point-in-time protocol state, not a screenshot or a separate persisted copy. It contains bounded summaries, never message bodies or terminal replay bytes, and populates and resynchronizes the session list and live-object list after connect. `AgentSummary` and `TerminalSummary` contain identity and list-display metadata only. Large root snapshots are paginated with an opaque `RootSnapshotCursor`: the first page freezes a logical baseline through event sequence `N`, later pages use its cursor, and each page respects `limit` and the negotiated frame size. Cursors have a short bounded lifetime; expiration returns `snapshotExpired` and the client restarts from the first page. Object snapshots provide the baseline to which later events are applied. `openAgent` binds the supplied protocol object ID and returns the initial `AgentSnapshot` atomically. `createTerminal` and `attachTerminal` bind the handle and return its initial `TerminalAttachmentSnapshot` atomically. A separate initial object `snapshot` call is therefore unnecessary.

Root events report session and live-object creation, update, and removal. Each event carries a monotonically increasing root `eventSequence`. Snapshot capture and event subscription are one daemon-isolated operation: events after `N` are buffered in the connection's normal bounded queue while all pages are fetched, and released after the final page. The first later event is `N + 1`. A duplicate sequence is ignored; a higher-than-expected sequence is a gap and requires a fresh root snapshot. Sequence history need not be retained because the snapshot is the recovery mechanism.

Root buffering is bounded, including while paginated snapshot pages are outstanding. If it overflows, the daemon invalidates the root subscription, discards its queued data events, and sends `subscriptionInvalidated(scope: root)` through the reserved control lane. No later root events are sent until the client starts a new snapshot. If the invalidation notice cannot be queued, the daemon closes the connection. A cursor from an invalidated snapshot returns `snapshotInvalidated`; the client discards all of its pages and starts again.

`deleteSession` fails with `sessionInUse` while a live agent exists for the session. Closing that agent through its attached object is required first. Root requests cannot close agents or terminate terminals by daemon-generation-scoped ID; destructive live-object operations require an authorized attachment.

### Agent object

Agent requests:

```text
snapshot
messages(after: MessageCursor?, before: MessageCursor?, limit: UInt32)
turnSnapshot(turnID: UInt64, afterPart: UInt64?, limit: UInt32)
submit(text)
interrupt
clearQueue
sendQueued(strategy)
setProfile(name)
fork(boundary)
tldr(startBoundary, endBoundary)
close
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
queueChanged
usageChanged
turnFinished
```

The wire events are stable client-facing messages. The existing internal `AgentEvent` enum is not serialized directly. Each agent event carries a monotonically increasing, agent-local `eventSequence`.

`messages` returns persisted messages in document order, their opaque cursors, and pagination boundaries. Omitting both cursors returns the newest page. Supplying both cursors is invalid. `turnSnapshot` returns ordered, numbered parts of the unfinished turn and a continuation position. Responses must fit the negotiated frame size; the daemon may return fewer than `limit` items and a single message, turn part, or tool payload that cannot fit is returned through chunked message-content frames. A newly attached GUI loads history through these APIs rather than reading daemon-host files.

Agent snapshot capture and event subscription are atomic. If the snapshot is through sequence `N`, subsequent events begin at `N + 1`. On a gap, the client requests a fresh snapshot, reconciles persisted history from `latestMessageCursor`, and replaces any partial rendering from the paginated `currentTurnID` snapshot. Agent event sequences are transient and restart with a new live agent; message cursors are the durable history boundary. `close` is accepted only on the attached agent object, stops its turn, unloads it, and preserves the durable session.

Agent event and snapshot-pagination buffering is bounded. Overflow invalidates that handle's subscription, drops queued data events, and sends `subscriptionInvalidated(scope: agent, latestMessageCursor, currentTurnID)` through the reserved control lane; no later agent events are sent on the invalidated handle. Failure to queue the notice closes the handle. Recovery uses the attached object's `snapshot`, followed by `messages` and, when present, `turnSnapshot`; the running turn is not interrupted. Requests using continuations from an invalidated snapshot return `snapshotInvalidated`.

### Common attached-object lifecycle

```text
detach
```

`detach` is sent to an attached agent or terminal object. It removes only that connection's handle, event subscription, and queued outbound data; it does not close the agent, delete the session, terminate the terminal process, or remove the terminal object. Explicit detach is needed when a tab closes but the shared daemon connection remains open. Otherwise those resources are also released automatically when the connection closes. Putting `detach` on the target object avoids a root-level `detachObject(objectID)` bookkeeping API.

### Terminal object

Terminal requests:

```text
snapshot
input(bytes)
resize(columns, rows)
terminateProcess
close
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

The attached-object `snapshot` request returns a `TerminalAttachmentSnapshot`, including the requesting handle's current access. Terminal replay, input, and output payloads are raw bytes, not JSON or base64. An output or replay event payload starts with an eight-byte, big-endian `UInt64` offset followed by the bytes. The offset is the absolute position of the first byte. The next expected offset is `offset + bytes.count`. Byte payloads are split so every complete frame is at most the negotiated maximum frame size; PTY read boundaries have no protocol meaning.

### Terminal stream behavior

The PTY read path never waits for a GUI or socket write. For every read, the terminal object assigns offsets, appends the bytes to its shared replay buffer, and enqueues output independently for each attached connection. Socket writes preserve output order for each terminal.

Attaching is atomic with respect to output. The daemon first subscribes the handle and captures a `TerminalAttachmentSnapshot` containing terminal metadata, retained range `R..<N`, and that handle's controller or observer access. The response contains metadata only. It is followed by chunked raw `replay` frames covering a contiguous suffix `R'..<N`, where `R' >= R` if pressure evicted bytes while the response was in flight, and then by live `output` frames beginning at `N`. If `R' > R`, `replayInvalidated` precedes replay so the client can mark the display incomplete. Output produced after the baseline is queued behind replay for that handle, so no byte can slip between replay and live output. All frames obey the negotiated maximum size.

A client initializes its next expected byte offset from the first replay frame (or `N` when replay is empty), then tracks it across replay and live output:

- An equal offset is the next byte range.
- A lower offset is duplicate output and is trimmed or ignored.
- A higher offset is a gap and requires a fresh attachment baseline.

Each connection has a bounded outbound data queue plus a reserved, bounded control lane. A slow client must not stall the PTY or other clients. When a client falls behind, the daemon drops that terminal handle's queued output and sends `replayInvalidated` through the control lane. No later output is sent on that invalidated handle. If the control notice cannot be queued, the daemon closes the handle, which is itself observable as an object/connection closure; it never leaves an idle client waiting silently.

Recovery uses `attachTerminal` with a fresh, unused `ObjectID`. The operation atomically replaces any invalidated handle for that terminal on the same connection and establishes a new snapshot/replay/live-output baseline. The old handle is closed after the new baseline is installed. If the retained range no longer includes the missing bytes, the GUI performs the best-effort reset and replay described above.

In the first version, only one attached client may send input, resize, `terminateProcess`, or `close` on a terminal. Other attachments are observers. The first attachment is the controller; control transfers after it detaches or disconnects, and every remaining handle receives `accessChanged` when its capability changes. This avoids interleaved input and competing window sizes. A later protocol version can add explicit control acquisition if needed. Root snapshots expose no capability that bypasses this check.

Terminal control uses the same ownership-epoch rule as agents. Input and destructive requests accepted under an old controller epoch are rejected with `staleAttachment` if control transfers before they execute. Output delivery is unaffected.

The daemon emits all final readable PTY output before `exited`. `terminateProcess` signals a running child and retains the exited terminal, replay, and status for inspection. `close` removes the terminal object and replay, closing all of its handles; if the child is still running, the daemon terminates it and drains final PTY output before removal. Exited terminals otherwise remain attachable until `close` or the daemon's retention policy removes them.

## Connections

### Local

```text
GUI -> ~/.scribe/run/daemon.sock -> scribe-daemon
```

On launch, the GUI connects locally. If the socket is unavailable, it starts `scribe-daemon serve` and retries.

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

### Chunked message content

A JSON response or event that contains a field too large for one frame replaces that field with a `ChunkedContentReference`:

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
}
```

The client must advertise `minimumVersion > 0`, `minimumVersion <= maximumVersion`, and `maximumFrameSize` at least the protocol's fixed minimum frame size. Version 1 uses a minimum of 4 KiB, which is also the server's maximum accepted bootstrap-frame size. The negotiated frame size is the smaller of the client's value and the server's configured limit and must still meet that selected version's minimum. Invalid ranges or sizes receive `invalidHello` and the connection closes. Before hello completes, the decoder caps the frame at the bootstrap limit; afterward it applies the negotiated limit before allocating payload storage.

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
5. **Local daemon transport.** Add `scribe-daemon serve`, Unix socket lifecycle and permissions, and map one connection onto the already-tested terminal runtime. Add create, attach, input, resize, process termination, and object close integration tests. Chat support is not required here.
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
