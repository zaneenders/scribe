# Scribe Daemon Plan

## Goal

Keep chats, agents, and terminals alive when the GUI disconnects, locally or over SSH.

The daemon owns session access, running agents, and PTYs. Sessions persist across daemon restarts; running agents and terminals do not. Implementation details are intentionally deferred to the PR that introduces each boundary.

## Steps

1. **Extract the terminal runtime.** Put `PTYSession` behind a transport-independent runtime with bounded replay and attachments. Keep the GUI working through an in-process client and test output, input, resize, exit, replay, and slow consumers.

2. **Add process lifecycle management.** Ensure terminal and agent child processes are terminated and reaped on explicit close, daemon shutdown, and daemon crash.

3. **Add the protocol library.** Define versioned framing, typed IDs, request/response/event routing, bounded payloads, errors, and reconnectable snapshots. Test it without sockets.

4. **Add the local daemon.** Implement `scribe-daemon serve` over a secure Unix socket with one daemon per Scribe data directory. Expose terminal create, attach, control, detach, and close.

5. **Move the GUI terminal client to the daemon.** Replace the in-process terminal adapter with a network adapter without changing terminal rendering.

6. **Extract the agent and session runtime.** Put session discovery, persistence, profiles, message history, queues, and `SessionHarness` behind a transport-independent runtime and in-process client.

7. **Expose chats through the daemon.** Add session and agent protocol operations, subscriptions, reconnect recovery, and exclusive session ownership; then move the GUI chat client to the daemon.

8. **Add SSH transport.** Implement the byte-only remote bridge and GUI SSH connection to the same daemon protocol.

9. **Finish distribution.** Move setup and auth commands to `scribe-daemon`, package the daemon and process helper, define upgrade behavior, and remove deprecated Slate entry points.
