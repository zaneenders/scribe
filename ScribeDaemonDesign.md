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
struct AgentSnapshot: Codable, Sendable {
  let id: AgentID       // daemon-scoped live object ID
  let sessionID: SessionID  // same durable ID as Session.id
  var state: AgentState
  var queuedMessages: [String]
}

enum AgentState: String, Codable, Sendable {
  case idle
  case running
  case interrupting
  case failed
}
```

Internally, the existing `SessionHarness` owns the session document, persistence, model configuration, in-memory message queue, and running turn. It is not sent over the protocol. Queued messages are lost when the agent or daemon exits.

`SessionID` names the existing durable session UUID; it does not introduce a different wire representation. `AgentSnapshot.sessionID` is always the same value as `Session.id` for the session that agent has open. It is distinct from `AgentSnapshot.id`, which identifies only the daemon-scoped live agent object.

Only one live agent and one client connection may own a session at a time. The daemon enforces this with an exclusive attachment, not merely a UI convention:

- The daemon keeps a `SessionID -> AgentID` map and an `AgentID -> connection` attachment map.
- `openAgent` checks and updates both maps as one daemon-isolated operation. If another connection owns the agent, it returns `sessionInUse`; it never creates a second `SessionHarness`.
- All mutating agent requests are accepted only from that attached connection and are processed serially by the agent runtime.
- Detach or connection loss releases the attachment. It does not stop an in-flight turn or unload the agent. The first later `openAgent` attaches to that same live agent and receives its current state.
- Closing the agent explicitly stops its turn and unloads it, but leaves the durable session on disk.

A GUI that wants two views of one session must fan out one attachment inside that GUI; it cannot create two protocol attachments. Attachment ownership is tied to the transport connection, so a crashed or disconnected client cannot leave a timed stale lock. This prevents two machines from submitting, interrupting, changing profiles, or otherwise racing one session. `SessionHarness` remains the sole persistence writer.

### Terminal object

A terminal object is a live PTY and shell process.

```swift
struct TerminalSnapshot: Codable, Sendable {
  let id: TerminalID    // daemon-scoped live object ID
  var title: String?
  var workingDirectory: String
  var columns: UInt16  // canonical PTY width in character cells
  var rows: UInt16     // canonical PTY height in character cells
  var processState: TerminalProcessState
  var replayStartOffset: UInt64
  var nextOutputOffset: UInt64
  var recentOutput: Data
}

enum TerminalProcessState: Codable, Sendable {
  case running
  case exited(status: Int32)
}
```

The daemon owns the PTY file descriptor and child process. It retains a bounded amount of recent raw PTY output for reattachment. Terminal state is memory-only: the PTY, child process, dimensions, replay bytes, and terminal IDs disappear when the daemon exits. Nothing in `TerminalSnapshot` is written to the session files.

The dimensions matter because a PTY has a kernel window size. Shells and full-screen programs use it for wrapping and layout, and a resize updates the PTY with `TIOCSWINSZ` and causes `SIGWINCH`. The daemon keeps one canonical size so the process still has a defined window while no GUI is attached and a reconnecting GUI knows the size that produced the retained output. `UInt16` matches the PTY `winsize` fields; requests must reject zero or unsupported values. While attached, only the controlling client may resize it.

This is broadly how tmux works: a long-lived tmux server owns the PTYs, child processes, pane sizes, and scrollback in memory while clients attach and detach. Killing the tmux server (or rebooting the host) kills those live terminals. Tools such as tmux-resurrect can save commands and layouts, but they do not persist the original processes. Scribe's first version does not provide that kind of terminal restoration. Output positions are absolute byte offsets, not PTY read or protocol-frame numbers. `recentOutput` contains exactly the half-open range `replayStartOffset..<nextOutputOffset`.

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

The daemon allocates live IDs and does not reuse one while it remains live. A client must discard them whenever its connection or the daemon generation changes.

Each connection addresses attached objects with small `ObjectID` handles:

```text
object 0   daemon/root
object 1   attached agent
object 2   attached terminal
```

These object IDs are handles for one client connection. They are neither the durable session UUID nor the daemon-scoped `AgentID` or `TerminalID`. Agents and terminals do not have UUIDs because they are never restored from disk.

- Detaching or disconnecting drops the handle only.
- Closing an agent stops that live agent but keeps its session.
- Terminating a terminal kills its process.
- Deleting a session removes durable chat data.

## API

### Root object: object `0`

```swift
struct DaemonSnapshot: Codable, Sendable {
  var sessions: [Session]
  var agents: [AgentSnapshot]
  var terminals: [TerminalSnapshot]
}
```

Root requests:

```text
snapshot
createSession
openAgent(sessionID: SessionID, newObjectID: ObjectID)
closeAgent(agentID: AgentID)
deleteSession(sessionID: SessionID)
createTerminal(workingDirectory, columns, rows, newObjectID: ObjectID)
attachTerminal(terminalID: TerminalID, newObjectID: ObjectID)
terminateTerminal(terminalID: TerminalID)
```

A snapshot is a complete, point-in-time protocol state, not a screenshot or a separate persisted copy. The root snapshot populates and resynchronizes the session list and live-object list after connect. Object snapshots provide the baseline to which later events are applied. This is why `snapshot` exists even though the UI normally stays current through events: a client needs a bounded way to bootstrap or recover after losing event continuity. `openAgent`, `createTerminal`, and `attachTerminal` bind the supplied protocol object ID and return the initial object snapshot atomically, so a separate initial `snapshot` call is unnecessary.

Root events report session and live-object creation, update, and removal after that baseline. A client may request a new root snapshot if it detects a gap.

### Agent object

Agent requests:

```text
snapshot
submit(text)
interrupt
clearQueue
sendQueued(strategy)
setProfile(name)
fork(boundary)
tldr(startBoundary, endBoundary)
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

The wire events are stable client-facing messages. The existing internal `AgentEvent` enum is not serialized directly.

### Common attached-object lifecycle

```text
detach
```

`detach` is sent to an attached agent or terminal object. It removes only that connection's handle, event subscription, and queued outbound data; it does not close the agent, delete the session, or terminate the terminal. Explicit detach is needed when a tab closes but the shared daemon connection remains open. Otherwise those resources are also released automatically when the connection closes. Putting `detach` on the target object avoids a root-level `detachObject(objectID)` bookkeeping API.

### Terminal object

Terminal requests:

```text
snapshot
input(bytes)
resize(columns, rows)
terminate
```

Terminal events:

```text
output(offset, bytes)
resized(columns, rows)
replayInvalidated(availableFromOffset, nextOutputOffset)
exited(status)
```

Terminal input and output payloads are raw bytes, not JSON or base64. An output event payload starts with an eight-byte, big-endian `UInt64` offset followed by the output bytes. The offset is the absolute position of the first byte. The next expected offset is `offset + bytes.count`. Output may be split to respect the negotiated maximum frame size; PTY read boundaries have no protocol meaning.

### Terminal stream behavior

The PTY read path never waits for a GUI or socket write. For every read, the terminal object assigns offsets, appends the bytes to its shared replay buffer, and enqueues output independently for each attached connection. Socket writes preserve output order for each terminal.

Attaching is atomic with respect to output. The attach response contains a `TerminalSnapshot`. If its `nextOutputOffset` is `N`, every later output event for that handle starts at `N` and continues in increasing offset order. No output may slip between taking the snapshot and subscribing the handle.

A client tracks the next expected byte offset:

- An equal offset is the next live output.
- A lower offset is duplicate output and is trimmed or ignored.
- A higher offset is a gap and requires a fresh snapshot.

Each connection has a bounded outbound queue. A slow client must not stall the PTY or other clients. When a client falls behind, the daemon drops that terminal handle's queued output and sends `replayInvalidated` if possible; the client then attaches again. If the retained range no longer includes the missing bytes, the GUI performs the best-effort reset and replay described above.

In the first version, only one attached client may send input or resize a terminal. Other attachments are observers. The first attachment is the controller; control transfers after it detaches or disconnects. This avoids interleaved input and competing window sizes. A later protocol version can add explicit control acquisition if needed.

The daemon emits all final readable PTY output before `exited`. An exited terminal remains attachable so its final output and status can be inspected until it is explicitly terminated or cleaned up by the daemon's retention policy.

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

- `version` is the selected protocol version.
- `code` identifies the request, response, or event.
- `objectID` identifies the target protocol object.
- `requestID` correlates a request and response; events use zero.
- `payloadLength` is the number of bytes after the header.

Control payloads use JSON encoded with `Codable`. Terminal byte messages use raw payloads.

## Handshake

The first request is `hello` on object `0`.

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

Every successful connection starts a new live-ID namespace. On disconnect, the GUI discards agent IDs, terminal IDs, protocol handles, and event positions; it must obtain fresh values after reconnecting. Only durable session UUIDs may be retained. This avoids giving an in-memory daemon instance a UUID or persisting a generation counter solely to detect improbable numeric reuse.

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
5. **Local daemon transport.** Add `scribe-daemon serve`, Unix socket lifecycle and permissions, and map one connection onto the already-tested terminal runtime. Add create, attach, input, resize, and terminate integration tests. Chat support is not required here.
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
