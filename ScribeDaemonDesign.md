# Scribe Daemon Design

## Goal

`scribe-daemon` keeps chats and terminals alive when the GUI closes or disconnects.

- The GUI connects to the local daemon automatically.
- The GUI can switch to a remote daemon over SSH.
- Chat history is stored on the daemon host.
- A running agent continues while the daemon is alive.
- A terminal process continues while the daemon is alive.
- Chat history survives daemon restart; agents and terminals do not.
- The Slate TUI are deprecated. Setup commands move to `scribe-daemon`.

## Things the daemon owns

### Chat history

A chat history is the existing persisted Scribe session. Its UUID is durable.

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

The existing session files remain the source of truth for messages and metadata. This design does not introduce a second chat-storage format.

### Agent object

An agent object is the live agent working on a chat history.

```swift
struct AgentSnapshot: Codable, Sendable {
  let id: UInt32        // daemon-scoped live object ID
  let sessionID: SessionID  // same durable ID as Session.id
  var state: AgentState
  var queuedTexts: [String]
}

enum AgentState: String, Codable, Sendable {
  case idle
  case running
  case interrupting
  case failed
}
```

Internally, the existing `SessionHarness` does this work: it owns the session document, persistence, selected model configuration, message queues, and running turn. It stays an internal implementation detail and is not sent over the protocol.

`SessionID` names the existing durable session UUID; it does not introduce a different wire representation. `AgentSnapshot.sessionID` is always the same value as `Session.id` for the session that agent has open. It is distinct from `AgentSnapshot.id`, which identifies only the daemon-scoped live agent object.

Only one live agent writes a session. Opening an already-live session attaches to its existing agent.

### Terminal object

A terminal object is a live PTY and shell process.

```swift
struct TerminalSnapshot: Codable, Sendable {
  let id: UInt32        // daemon-scoped live object ID
  var title: String?
  var workingDirectory: String
  var columns: UInt16
  var rows: UInt16
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

The daemon owns the PTY file descriptor and child process. It retains a bounded amount of recent raw PTY output for reattachment. Output positions are absolute byte offsets, not PTY read or protocol-frame numbers. `recentOutput` contains exactly the half-open range `replayStartOffset..<nextOutputOffset`.

The GUI continues to own `GhosttyTerminal`, which turns VT bytes into cells and render state. The daemon does not persist terminal emulator state and does not restore terminals after daemon exit.

Reattachment is best effort in the first version. A bounded suffix of VT output cannot always reconstruct a terminal exactly because it may depend on older cursor, screen, or mode changes. This is especially visible for long-running full-screen programs. When older output has been discarded, the GUI resets its emulator, replays the retained bytes, and indicates outside the PTY stream that earlier output and display state may be incomplete.

## Protocol objects

Each connection addresses objects with small `UInt32` IDs:

```text
object 0   daemon/root
object 1   attached agent
object 2   attached terminal
```

These IDs are handles for one client connection. They are not the chat-history UUID, agent UUID, or terminal UUID.

- Detaching or disconnecting drops the handle only.
- Closing an agent stops that live agent but keeps its history.
- Terminating a terminal kills its process.
- Deleting a history removes durable chat data.

## API

### Root object: object `0`

```swift
struct DaemonSnapshot: Codable, Sendable {
  var histories: [Session]
  var agents: [AgentSnapshot]
  var terminals: [TerminalSnapshot]
}
```

Root requests:

```text
snapshot
createHistory
openAgent(sessionID: SessionID, newObjectID)
closeAgent(agentID: UInt32)
deleteHistory(sessionID: SessionID)
createTerminal(workingDirectory, columns, rows, newObjectID)
attachTerminal(terminalID: UInt32, newObjectID)
terminateTerminal(terminalID: UInt32)
detachObject(objectID)
```

`openAgent`, `createTerminal`, and `attachTerminal` bind the supplied protocol object ID and return the initial object snapshot.

### Agent object

Agent requests:

```text
snapshot
submit(text)
interrupt
clearQueue
sendNextQueued
setProfile(name)
fork(boundary)
tldr(startBoundary, endBoundary)
```

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
  var objectID: UInt32
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
  var daemonInstanceID: UUID
  var maximumFrameSize: UInt32
}
```

The daemon instance ID changes when the daemon restarts. The GUI then discards live agent IDs, terminal IDs, protocol handles, and event positions. Durable chat-history UUIDs remain valid.

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
2. Should queued messages survive daemon restart?
3. How are multiple clients authorized to submit agent messages?
4. What numeric opcodes map to the API above?
5. How long should exited terminal objects remain available?
6. What per-connection and daemon-wide memory limits should ship as defaults?
