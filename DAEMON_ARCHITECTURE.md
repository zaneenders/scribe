# Daemon Client–Server Architecture

## Summary

Scribe should move toward a client–server architecture in which a daemon is the authoritative owner of sessions, while the macOS and Wayland applications act as graphical clients. The same daemon supports clients on its own machine and clients connecting from another machine; “local” always means local to the daemon host.

This is a good fit for Scribe because sessions already want to run independently of which conversation is visible. A daemon makes it natural for an agent turn to continue when the user switches sessions or closes the GUI. Its host filesystem is authoritative: working directories and tool calls always refer to the machine running the daemon, regardless of where the GUI runs.

The current ownership boundary is blurred:

- `ScribeMacStore` owns the collection of live sessions.
- `SessionController` owns both presentation state and running agent work.
- `SessionHarness` is already an actor and is effectively the core of a server-side session.
- `ChatSessionStore` is accessed directly by front ends, which can create multi-process writer races if the CLI and GUI are open together.

A daemon provides one authoritative owner for running sessions and persistence.

## Decisions

- There is one daemon executable and one API for same-host and network clients; a remote connection is not a different server architecture.
- The daemon host is authoritative for sessions, profiles, filesystem paths, tool execution, and terminal processes.
- Commands use generated OpenAPI HTTP operations.
- Daemon-to-client agent updates use SSE: one global stream plus per-session streams.
- Historical transcripts and directory listings use opaque cursor pagination rather than event streams.
- The daemon authenticates requests with a bearer token. Same-host discovery obtains it from a protected descriptor; network connections obtain it from saved server configuration.
- The daemon serves HTTP. Caddy or another reverse proxy owns HTTPS and public ingress when required.
- Terminal sessions are tmux-like resources owned by the daemon. GUI disconnects detach rather than terminate them; terminal byte transport will be designed separately from SSE.

## Proposed Architecture

```text
scribe-mac / scribe-wayland / eventually scribe CLI
                    │
     OpenAPI HTTP commands + SSE events
       (same-host or network connection)
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
 daemon-host filesystem + ~/.scribe/sessions + config
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
- The daemon host's default working directory and allowed filesystem roots
- Directory browsing, pagination, completion, and path canonicalization
- Working-directory authorization and validation when a session is created
- Long-lived terminal sessions and their PTYs, including process lifetime and scrollback

### GUI responsibilities

The graphical clients should own:

- Window and sidebar state
- Active tab and session selection
- Composer draft and prompt-history navigation
- Rendering transcript DTOs
- Scroll and focus state
- Rendering terminal cells and forwarding input and resize events to daemon-managed terminal sessions

Under this design, `SessionController` becomes a client-side state projection rather than directly containing a `BootstrappedSession` and calling `SessionHarness`.

## Why Swift Hummingbird

Hummingbird is a good fit because:

- Scribe already uses SwiftNIO.
- It is portable across macOS and Linux.
- HTTP APIs are easy to inspect, test, and debug.
- Streaming HTTP responses fit SSE agent events.
- The same API supports same-host, remote, and headless clients.
- It avoids committing the architecture to macOS-only XPC.

Use regular OpenAPI HTTP operations for commands, one global Server-Sent Events (SSE) stream for session-list changes, and per-session SSE streams for detailed agent events. This keeps token streaming and reconnect support within the generated OpenAPI client/server contract.

## Initial API

A first API could look like this:

```text
GET    /v1/health
GET    /v1/profiles
GET    /v1/filesystem
GET    /v1/filesystem/directories?parent={path}&cursor={cursor}&limit=50
POST   /v1/filesystem/resolve-directory
POST   /v1/filesystem/complete-directory
GET    /v1/filesystem/recent-directories?cursor={cursor}&limit=50

GET    /v1/sessions
POST   /v1/sessions  (supports Idempotency-Key; defaults working directory server-side)
GET    /v1/sessions/{id}
PATCH  /v1/sessions/{id}
GET    /v1/sessions/{id}/messages?before={cursor}&limit=50
POST   /v1/sessions/{id}/messages
POST   /v1/sessions/{id}/interrupt
DELETE /v1/sessions/{id}/queue
POST   /v1/sessions/{id}/queue/send-next
POST   /v1/sessions/{id}/fork
POST   /v1/sessions/{id}/tldr
PUT    /v1/sessions/{id}/profile
DELETE /v1/sessions/{id}/open

GET    /v1/events  (text/event-stream)
GET    /v1/sessions/{id}/events?afterRevision={revision}  (text/event-stream)
```

`DELETE /v1/sessions/{id}/open` would mean “release this live session if nothing else needs it,” not delete persisted history. Alternatively, sessions could remain loaded until idle eviction or daemon shutdown.

Directory discovery and path resolution run on the daemon. The daemon advertises its default directory and allowed roots, provides opaque-cursor pagination over direct child directories, and revalidates the selected directory when creating a session. All returned paths and all tool working directories belong to the daemon host. Directory browsing is non-recursive; global project search can be added later as a separate capability.

Historical transcript entries should be fetched through opaque cursor pagination rather than sent over SSE. The client fetches the newest page when opening a session and requests older pages as the user scrolls upward. It owns viewport virtualization and preserves the scroll anchor when prepending a page.

`GET /v1/events` carries lightweight global session-list changes. A client opens `GET /v1/sessions/{id}/events` only for sessions it is displaying, so detailed token and tool events are not broadcast unnecessarily. The daemon still runs background sessions and publishes summary state changes globally.

## Wire Protocol

Internal types such as `AgentEvent` should not be exposed directly over the network. Create a separate `ScribeAPI` target whose `openapi.yaml` is the source of truth for stable request, response, snapshot, and event DTOs. Use Swift OpenAPI Generator to generate shared types plus client and server protocols.

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

All API operations, including SSE subscriptions, use the same daemon bearer token:

```http
Authorization: Bearer <daemon-token>
```

The OpenAPI document should declare this as a global HTTP bearer security scheme so generated clients and server handlers share the requirement. Authentication establishes the client's access to a daemon; filesystem-root authorization and all session operations are enforced server-side. Credentials and provider API keys are never returned through profile or health responses.

### Event ordering and reconnects

Every event should have a monotonically increasing ID or per-session sequence number.

On SSE reconnect, using `Last-Event-ID`:

1. The client sends its last observed event ID or session revision.
2. The daemon replays events from a bounded ring buffer when possible.
3. If replay is not possible, the daemon tells the client to fetch a fresh session snapshot.
4. The client rebuilds its local projection from the authoritative snapshot.

When first subscribing to a session, the client passes the snapshot's revision as `afterRevision`. This closes the race between fetching the snapshot and opening its detailed event stream.

The snapshot must always be the authoritative recovery mechanism.

### Live transcript projection

`SessionHarness` currently persists generated messages at the end of a turn. The daemon therefore needs an in-memory live transcript projection in addition to persisted messages. Otherwise, reconnecting during a stream could lose the visible partial answer until the turn completes.

## GUI Connection and Daemon Discovery

The GUI represents every daemon—whether on the same machine or another machine—as a saved server connection:

```swift
struct ServerConnection {
  let id: UUID
  let name: String
  let endpoint: Endpoint
}

enum Endpoint {
  case sameHostOnDemand(descriptorURL: URL)
  case connectOnly(baseURL: URL, credentialReference: String)
}
```

For `connectOnly`, `baseURL` is the complete origin used by the generated OpenAPI client, including scheme, host, and port when non-default. `credentialReference` points to secure credential storage rather than embedding the bearer token in ordinary GUI preferences. On macOS this should use Keychain; Linux should use an available desktop secret service, with a deliberately protected fallback for environments without one. For `sameHostOnDemand`, the rotating base URL and token come from the protected descriptor and are not copied into saved preferences.

The transport does not infer filesystem locality from the URL. Paths returned by a connection always belong to that daemon's host. Selecting a different server changes the available sessions, profiles, directories, tools, and terminals.

### Same-host connect-or-start

A same-host daemon publishes `~/.scribe/run/daemon.json` atomically with mode `0600`:

```json
{
  "pid": 12345,
  "baseURL": "http://127.0.0.1:49182",
  "token": "random-secret",
  "protocolVersion": 1,
  "daemonInstanceID": "00000000-0000-0000-0000-000000000001"
}
```

The descriptor is discovery data for processes running as the same OS user. It is not used to discover a daemon on another machine. `baseURL` is preferred over separate host and port fields so client construction has one canonical value.

Suggested same-host flow:

1. Read and validate the descriptor.
2. Construct an OpenAPI client using `baseURL` and bearer-token middleware.
3. Call `GET /v1/health` with a short deadline.
4. If unavailable, acquire the daemon startup lock.
5. Re-read the descriptor and retry health after obtaining the lock; another process may have started it.
6. Start or register the daemon if it is still unavailable.
7. Wait for a newly written descriptor and retry health with bounded backoff.
8. Verify the daemon instance, protocol version, and required capabilities.
9. Fetch initial profiles, filesystem metadata, and session summaries.
10. Open the global SSE stream.

A stale descriptor, dead PID, refused connection, mismatched daemon instance, or failed health check is recoverable discovery state, not proof that the session data is corrupt. Only the process holding the startup lock may launch a replacement.

### Network connection

For a daemon on another machine, the user configures a server name, base URL, and bearer credential. Its endpoint is `connectOnly`: the GUI never reads a descriptor, checks a remote PID, acquires a startup lock, or attempts to launch that daemon.

The network flow is:

1. Load the configured base URL and bearer credential.
2. Construct the same generated OpenAPI client and authentication middleware used for same-host operation.
3. Call `GET /v1/health` and verify protocol compatibility and capabilities.
4. Fetch profiles, filesystem metadata, and sessions.
5. Open the global SSE stream.

If Caddy fronts the daemon, the configured base URL is the Caddy URL. Redirects must not cause the bearer token to be forwarded to an unrelated origin. Connection failures remain associated with that saved server and must not trigger same-host daemon startup.

### Connection lifecycle

A client connection moves through explicit presentation states such as `disconnected`, `connecting`, `ready`, `reconnecting`, `incompatible`, and `authenticationFailed`. Once ready, the normal bootstrap sequence is:

```text
GET /v1/health
GET /v1/profiles
GET /v1/filesystem
GET /v1/sessions
GET /v1/events
```

The GUI keeps one global SSE subscription per connected server. When it displays a session, it first fetches the authoritative snapshot and then opens that session's SSE stream:

```text
GET /v1/sessions/{id}
GET /v1/sessions/{id}/events?afterRevision={snapshotRevision}
```

Commands and SSE streams share the same base URL, bearer credential, compatibility checks, and reconnect policy. Losing SSE does not imply commands are unavailable, and losing a GUI connection does not interrupt running agent turns or daemon-managed terminals.

### Platform process management

- **macOS:** use a per-user `LaunchAgent`; `SMAppService` is the clean app-integrated route.
- **Linux:** use a `systemd --user` service where available.
- **Development/fallback:** start `scribe daemon serve` as a detached user process, with a lock preventing duplicate instances.

For same-host use, the daemon should be lazy and start on demand rather than necessarily running at login. The GUI and CLI can share the same descriptor and startup-lock implementation. Network connections are always connect-only from the client's perspective.

## Transport and Security

The daemon uses the same HTTP and SSE API for same-host and network clients. It should have configurable listen addresses and ports. A same-host default may bind to an ephemeral port on `127.0.0.1` and publish that port in the descriptor file; a network deployment binds to an explicitly configured private address and port.

A Unix domain socket is attractive, but cross-platform generated-client support over a Unix socket tends to require custom plumbing. HTTP is simpler and keeps both deployment modes on one protocol.

The daemon is responsible for bearer-token authentication, strict request validation, and authorization of filesystem roots. Every HTTP command, SSE subscription, and future terminal attachment must authenticate. Same-host startup places a random token in the mode-`0600` descriptor and rotates it whenever the daemon starts. Network deployments receive their daemon token through server configuration rather than the local descriptor.

TLS and public ingress are intentionally outside the daemon. Deployments that need HTTPS place Caddy or another reverse proxy in front of it. The proxy must preserve `Authorization` and SSE response streaming, disable response buffering for SSE routes, and allow long-lived responses. The daemon should not implement certificate management. Deployments should normally keep an unencrypted network listener on a private interface or loopback behind the proxy rather than exposing it directly to an untrusted network.

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

The terminal should follow a tmux-like ownership model. The daemon owns each terminal session, its PTY, shell process, working directory, dimensions, and bounded scrollback. Closing or disconnecting a GUI only detaches that client; it does not terminate the shell. A client can later reattach from the same machine or another machine and recover the current terminal state.

Terminal execution is always on the daemon host, so it sees the same filesystem and working directory as agent tool calls. The GUI owns only rendering and interaction. It sends keyboard input, paste data, resize requests, and explicit lifecycle commands such as create, attach, detach, and terminate.

SSE remains the transport for agent and session events, but it is not suitable for the bidirectional terminal byte stream. Terminals need a separate low-latency, flow-controlled transport plus regular command operations for lifecycle management. The exact transport should be designed separately; likely options are a dedicated WebSocket or a pair of streaming HTTP requests. Whichever transport is chosen must support:

- Stable terminal session IDs independent of client connections
- Create, list, attach, detach, and explicit terminate operations
- Initial screen or scrollback synchronization on attach
- Ordered input and output with bounded buffering and backpressure
- PTY resize events
- Multiple observing clients with a defined input-owner policy
- Reconnection without restarting the shell
- Idle retention, scrollback limits, and daemon-restart behavior
- Authorization tied to the same daemon identity and filesystem policy

`swift-nio-ssh` is not required for this model because the daemon already runs on the machine that owns the shell. Direct SSH from the GUI would put shell lifetime outside the daemon and would not provide the desired detach/reattach semantics unless another server-side session manager such as tmux were introduced. SSH could still be an optional deployment tunnel for reaching the daemon, but it is not the terminal ownership protocol.

Terminal survival across a daemon process restart is a separate requirement from survival across GUI disconnects. Initially, terminal sessions may live for the lifetime of the daemon. Surviving daemon restarts would require handing PTYs to a persistent helper, adopting an external session manager, or implementing restoration semantics that start a new shell rather than preserving the original process.

### Computer-use tools

Moving agent execution into the daemon means tools execute in the daemon’s process context. Shell and file tools are a good fit, but computer-use permissions and graphical-session access are more complicated:

- On macOS, Accessibility and Screen Recording permissions attach to an executable identity.
- On Linux, a user service may not inherit the correct Wayland environment or socket.
- A headless client may have no graphical client available.

Define a capability boundary early. The daemon should advertise available capabilities, and GUI-dependent computer-use tools can eventually be brokered through a connected graphical client. The protocol should not assume that every tool is always daemon-local.

## Migration Plan

Avoid rewriting the application and introducing networking at the same time.

### 1. Create `ScribeAPI`

Make `ScribeAPI/openapi.yaml` the source of truth and generate stable request, response, snapshot, session summary, filesystem, capability, client, server, and event types.

### 2. Extract `SessionService`

Move session collection and lifecycle logic out of `ScribeMacStore` into an actor that can initially run in-process.

### 3. Split `SessionController`

Remove direct ownership of `BootstrappedSession`. Make the controller consume snapshots and events through a client abstraction.

### 4. Define a client abstraction

Client construction accepts a `ServerConnection`, resolves its credential, performs the health handshake, and returns the same abstraction for same-host and network daemons. Same-host startup is a connection policy around this abstraction rather than a different implementation.

```swift
protocol ScribeClient: Sendable {
  func listProfiles() async throws -> ProfileList
  func filesystemInfo() async throws -> FilesystemInfo
  func listDirectories(...) async throws -> DirectoryPage
  func resolveDirectory(...) async throws -> ResolvedDirectory
  func completeDirectory(...) async throws -> DirectoryCompletion
  func listRecentDirectories(...) async throws -> RecentDirectoryPage

  func listSessions() async throws -> [SessionSummary]
  func openSession(_ id: UUID) async throws -> SessionSnapshot
  func createSession(...) async throws -> SessionSnapshot
  func updateSession(...) async throws -> SessionSnapshot
  func submit(_ text: String, to id: UUID) async throws -> CommandAccepted
  func interrupt(_ id: UUID) async throws -> CommandAccepted
  func clearQueue(_ id: UUID) async throws -> SessionQueue
  func sendNextQueuedMessage(_ id: UUID) async throws -> CommandAccepted
  func fork(...) async throws -> SessionSnapshot
  func tldr(...) async throws -> CommandAccepted
  func setProfile(...) async throws -> SessionSnapshot
  func events() -> AsyncThrowingStream<GlobalEventEnvelope, Error>
  func events(for id: UUID) -> AsyncThrowingStream<SessionEventEnvelope, Error>
}
```

Implement `InProcessScribeClient` first. This validates the ownership split without adding network and process-management complexity.

### 5. Add `scribe-daemon`

Add a Hummingbird executable that wraps the same `SessionService`.

### 6. Add `HummingbirdScribeClient`

Implement generated OpenAPI HTTP commands, bearer-token middleware, and SSE events. Add saved server connections, then switch GUI startup to the selected connection's `sameHostOnDemand` or `connectOnly` endpoint.

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

Proceed with the daemon architecture and use Hummingbird for OpenAPI HTTP and SSE transport. The same daemon and API serve same-host and network clients; filesystem and tool semantics are always relative to the daemon host.

Start by introducing the in-process client/service boundary. The most important design work is the stable snapshot/event protocol and reconnect semantics; the Hummingbird route implementation should come afterward and remain comparatively straightforward.
