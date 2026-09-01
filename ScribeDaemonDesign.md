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
struct ChatHistorySummary: Codable, Sendable {
  let id: UUID
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
  let sessionID: UUID   // existing durable session UUID
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

Only one live agent writes a chat history. Opening an already-live history attaches to its existing agent.

### Terminal object

A terminal object is a live PTY and shell process.

```swift
struct TerminalSnapshot: Codable, Sendable {
  let id: UInt32        // daemon-scoped live object ID
  var title: String?
  var workingDirectory: String
  var columns: UInt16
  var rows: UInt16
  var isRunning: Bool
  var recentOutput: Data
}
```

The daemon owns the PTY file descriptor and child process. It retains a bounded amount of recent raw PTY output for reattachment.

The GUI continues to own `GhosttyTerminal`, which turns VT bytes into cells and render state. The daemon does not persist terminal emulator state and does not restore terminals after daemon exit.

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
  var histories: [ChatHistorySummary]
  var agents: [AgentSnapshot]
  var terminals: [TerminalSnapshot]
}
```

Root requests:

```text
snapshot
createHistory
openAgent(sessionID: UUID, newObjectID)
closeAgent(agentID: UInt32)
deleteHistory(sessionID: UUID)
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
output(sequence, bytes)
resized(columns, rows)
exited(status)
```

Terminal input and output payloads are raw bytes, not JSON or base64.

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

## Remaining decisions

1. How much terminal output should the daemon retain for reattachment?
2. When should an idle agent be unloaded?
3. Should queued messages survive daemon restart?
4. Can multiple clients send agent messages or terminal input at the same time?
5. What numeric opcodes map to the API above?
