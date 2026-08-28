# Local Daemon Client–Server Architecture

## Summary

Scribe should move toward a client–server architecture in which a local daemon is the authoritative owner of sessions, while the macOS and Wayland applications act as graphical clients.

This is a good fit for Scribe because sessions already want to run independently of which conversation is visible. A daemon makes it natural for an agent turn to continue when the user switches sessions or closes the GUI.

The current ownership boundary is blurred:

- `ScribeMacStore` owns the collection of live sessions.
- `SessionController` owns both presentation state and running agent work.
- `SessionHarness` is already an actor and is effectively the core of a server-side session.
- `ChatSessionStore` is accessed directly by front ends, which can create multi-process writer races if the CLI and GUI are open together.

A daemon provides one authoritative owner for running sessions and persistence.

## Proposed Architecture

```text
scribe-mac / scribe-wayland / eventually scribe CLI
                    │
           HTTP + WebSocket
                    │
              scribe-daemon
                    │
        ┌───────────┴───────────┐
        │ SessionRegistry actor │
        │   ManagedSession      │
        │     SessionHarness    │
        │     live projection   │
        └───────────┬───────────┘
                    │
       ~/.scribe/sessions + config
```

## Responsibility Boundaries

### Daemon responsibilities

The daemon should own:

- `SessionHarness`
- `SessionMessageQueues`
- Running agent tasks
- Session persistence and metadata
- Profile and configuration loading
- Fork, TLDR, and reconfiguration operations
- Session list and recency
- Live event fan-out
- Session rename and pin state

### GUI responsibilities

The graphical clients should own:

- Window and sidebar state
- Active tab and session selection
- Composer draft and prompt-history navigation
- Rendering transcript DTOs
- Scroll and focus state
- The embedded terminal, at least initially

Under this design, `SessionController` becomes a client-side state projection rather than directly containing a `BootstrappedSession` and calling `SessionHarness`.

## Why Swift Hummingbird

Hummingbird is a good fit because:

- Scribe already uses SwiftNIO.
- It is portable across macOS and Linux.
- HTTP APIs are easy to inspect, test, and debug.
- WebSockets fit streamed agent events.
- It leaves room for remote or headless clients later.
- It avoids committing the architecture to macOS-only XPC.

Use regular HTTP for commands and a multiplexed WebSocket for events rather than building a complete bidirectional RPC protocol over WebSockets.

## Initial API

A first API could look like this:

```text
GET    /v1/health
GET    /v1/sessions
POST   /v1/sessions
GET    /v1/sessions/{id}
PATCH  /v1/sessions/{id}
POST   /v1/sessions/{id}/messages
POST   /v1/sessions/{id}/interrupt
POST   /v1/sessions/{id}/fork
POST   /v1/sessions/{id}/tldr
POST   /v1/sessions/{id}/profile
DELETE /v1/sessions/{id}/open

WS     /v1/events
```

`DELETE /v1/sessions/{id}/open` would mean “release this live session if nothing else needs it,” not delete persisted history. Alternatively, sessions could remain loaded until idle eviction or daemon shutdown.

## Wire Protocol

Internal types such as `AgentEvent` should not be exposed directly over the network. Create a separate `ScribeProtocol` target containing stable, Codable DTOs.

For example:

```swift
struct EventEnvelope: Codable, Sendable {
  let protocolVersion: Int
  let eventID: UInt64
  let sessionID: UUID
  let sessionRevision: UInt64
  let payload: SessionEvent
}
```

Wire events should represent client-facing state rather than mirror every internal event exactly:

```swift
enum SessionEvent {
  case sessionChanged(SessionSummary)
  case userMessageAppended(MessageDTO)
  case assistantSectionStarted(...)
  case assistantTextAppended(...)
  case toolStarted(...)
  case toolFinished(...)
  case usageUpdated(...)
  case turnFinished(...)
  case sessionIdentityChanged(...)
}
```

This insulates the client–server protocol from internal `AgentEvent` refactors.

### Event ordering and reconnects

Every event should have a monotonically increasing ID or per-session sequence number.

On WebSocket reconnect:

1. The client sends its last observed event ID or session revision.
2. The daemon replays events from a bounded ring buffer when possible.
3. If replay is not possible, the daemon tells the client to fetch a fresh session snapshot.
4. The client rebuilds its local projection from the authoritative snapshot.

The snapshot must always be the authoritative recovery mechanism.

### Live transcript projection

`SessionHarness` currently persists generated messages at the end of a turn. The daemon therefore needs an in-memory live transcript projection in addition to persisted messages. Otherwise, reconnecting during a stream could lose the visible partial answer until the turn completes.

## Daemon Startup and Discovery

The GUI should connect to the daemon and start it if it is unavailable.

Suggested flow:

1. Read `~/.scribe/run/daemon.json`.
2. Try `GET /v1/health`.
3. If unavailable, acquire a startup lock.
4. Re-check health after acquiring the lock.
5. Start or register the daemon.
6. Retry health with a short deadline.
7. Verify protocol version and capabilities.
8. Connect the event WebSocket.

Example descriptor:

```json
{
  "pid": 12345,
  "port": 49182,
  "token": "random-secret",
  "protocolVersion": 1
}
```

The descriptor should be written atomically with permissions restricted to the current user.

### Platform process management

- **macOS:** use a per-user `LaunchAgent`; `SMAppService` is the clean app-integrated route.
- **Linux:** use a `systemd --user` service where available.
- **Development/fallback:** start `scribe daemon serve` as a detached user process, with a lock preventing duplicate instances.

The daemon should be lazy and start on demand rather than necessarily running at login. The GUI and CLI can share the same connect-or-start implementation.

## Transport and Security

For the first version, bind Hummingbird to an ephemeral port on `127.0.0.1` and publish the chosen port in the descriptor file.

A Unix domain socket is attractive, but WebSocket support over a Unix socket tends to require custom plumbing. Loopback HTTP is simpler and portable.

Loopback is not itself an authentication boundary. A browser page can attempt requests to localhost. The daemon should use:

- A random bearer token stored in a mode-`0600` descriptor
- Strict `Host` and `Origin` checks
- No permissive CORS policy
- Binding only to `127.0.0.1` and, if needed, `::1`
- A protocol-version handshake
- Token rotation whenever the daemon starts

Exposing Scribe over a LAN should be treated as a separate security mode requiring TLS and explicit user authorization.

## Session Registry

The daemon maps naturally onto the existing actor model:

```swift
actor SessionRegistry {
  private var sessions: [UUID: ManagedSession]

  func create(...) async throws -> SessionSnapshot
  func open(id: UUID) async throws -> SessionSnapshot
  func submit(id: UUID, text: String) async throws
  func interrupt(id: UUID) async
  func snapshot(id: UUID) async throws -> SessionSnapshot
}
```

Each `ManagedSession` should own:

- `SessionHarness`
- `SessionMessageQueues`
- The current turn `Task`
- A live transcript projection
- Subscribers and event broadcasting
- Session summary metadata
- Last-used timestamp

This centralizes the single-running-turn rule and queued or force-send semantics, which currently live partly in `SessionController`.

## Complications at the Boundary

### Embedded terminal

Keep `SessionTerminal` and its PTY in the GUI initially. It is presentation-oriented, and moving it into the daemon requires a separate terminal byte-stream and resize protocol.

Move it server-side only if shells need to survive GUI restarts. That can be added later without blocking the core session architecture.

### Computer-use tools

Moving agent execution into the daemon means tools execute in the daemon’s process context. Shell and file tools are a good fit, but computer-use permissions and graphical-session access are more complicated:

- On macOS, Accessibility and Screen Recording permissions attach to an executable identity.
- On Linux, a user service may not inherit the correct Wayland environment or socket.
- A headless client may have no graphical client available.

Define a capability boundary early. The daemon should advertise available capabilities, and GUI-dependent computer-use tools can eventually be brokered through a connected graphical client. The protocol should not assume that every tool is always daemon-local.

## Migration Plan

Avoid rewriting the application and introducing networking at the same time.

### 1. Create `ScribeProtocol`

Add stable Codable request, response, snapshot, session summary, capability, and event types.

### 2. Extract `SessionService`

Move session collection and lifecycle logic out of `ScribeMacStore` into an actor that can initially run in-process.

### 3. Split `SessionController`

Remove direct ownership of `BootstrappedSession`. Make the controller consume snapshots and events through a client abstraction.

### 4. Define a client abstraction

```swift
protocol ScribeClient: Sendable {
  func listSessions() async throws -> [SessionSummary]
  func openSession(_ id: UUID) async throws -> SessionSnapshot
  func createSession(...) async throws -> SessionSnapshot
  func submit(_ text: String, to id: UUID) async throws
  func events() -> AsyncThrowingStream<EventEnvelope, Error>
}
```

Implement `InProcessScribeClient` first. This validates the ownership split without adding network and process-management complexity.

### 5. Add `scribe-daemon`

Add a Hummingbird executable that wraps the same `SessionService`.

### 6. Add `HummingbirdScribeClient`

Implement HTTP commands and WebSocket events, then switch GUI startup to the connect-or-start flow.

### 7. Move CLI ownership later

The CLI can initially retain its direct mode. Once the protocol is stable, add daemon-backed operation so CLI and GUI can observe and interact with the same sessions.

## Benefits

The primary benefit is not HTTP itself; it is establishing one authoritative owner for running sessions and persistence.

This enables:

- Agent turns that survive GUI closure
- Thin macOS and Wayland clients
- CLI and GUI observation of the same session
- Straightforward multiple-window support
- Elimination of competing session-persistence writers
- Notifications emitted independently of the GUI lifecycle
- Future web, headless, or remote clients

## Recommendation

Proceed with the local daemon architecture and use Hummingbird for HTTP and WebSocket transport.

Start by introducing the in-process client/service boundary. The most important design work is the stable snapshot/event protocol and reconnect semantics; the Hummingbird route implementation should come afterward and remain comparatively straightforward.
