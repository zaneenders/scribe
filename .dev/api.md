# ScribeAgent API

> **North star.** This document describes the target API — what ScribeAgent is
> growing toward. Parts of this exist today; the rest is being built in
> `.dev/`. The agent is already usable from the CLI or behind a server, but
> the full surface below is what we're aiming for before shipping as a
> library for others.

With the goal of being consumed from any process, `ScribeCore` will expose
three run modes behind a single agent type. Every path uses the same core:
`ScribeAgent` + `AgentConfig` + tools + one of three run methods.

## Quick start

```swift
import ScribeCore

let config = AgentConfig(
    agentModel: "gemma4:26b",
    serverURL: "http://localhost:11434"   // Ollama
)

let agent = ScribeAgent(
    configuration: config,
    systemPrompt: "You are a helpful coding assistant.",
    tools: [ShellTool(), ReadFileTool(), WriteFileTool(), EditFileTool()]
)
```

## Configuration

`AgentConfig` carries everything needed to connect and tune the model.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `agentModel` | `String` | — | Model name |
| `serverURL` | `String` | `"https://api.openai.com"` | Base URL (no `/v1` suffix) |
| `bearerToken` | `String?` | `nil` | API key for providers that need auth |
| `contextWindow` | `Int` | `131072` | Token limit before compaction |
| `contextWindowThreshold` | `Double` | `0.85` | Fraction of window that triggers compaction |

The agent creates its HTTP client internally — no need to touch OpenAPI types.

## Three run modes

### 1. `runTurn` — library / server

One model turn: LLM call + optional tool-call loop, all resolved before returning.
The caller owns the message array and can persist or inspect it between turns.

```swift
var messages: [Components.Schemas.ChatMessage] = [
    .init(role: .system, content: "You are a coding assistant."),
    .init(role: .user, content: "Write a function that reverses a string."),
]

let outcome = try await agent.runTurn(
    messages: &messages,
    log: logger,
    onEvent: { event in /* stream tokens, track usage, etc. */ }
)

// Extract the final assistant reply
let reply = ChatHistory.lastAssistantText(from: messages)
```

`onEvent` receives a stream of `TranscriptEvent` values:
`.enterAssistantSection`, `.appendAssistantText`, `.usage`, `.toolRoundHeader`,
`.toolInvocation`, `.harnessError`, `.turnInterrupted`, etc.

Used by: **shape-tree** HTTP server, any library consumer that wants
turn-by-turn control.

### 2. `runInteractive` — CLI / TTY

Full interactive session: reads lines from stdin (or any `readUserLine` closure),
runs turns, persists conversation after each turn.

```swift
try await agent.runInteractive(
    onEvent: { event in /* render transcript */ },
    readUserLine: { readLine() },
    initialConversation: nil,             // resume a previous session
    onConversationPersist: { history in   // save to disk
        try? ChatSessionStore.save(...)
    },
    shouldAbortTurn: { ctrlCPressed },
    log: logger
)
```

The agent owns the run loop — it handles system-prompt injection, token tracking,
context-window compaction, and exit on Ctrl+D / `"exit"`.

Used by: **scribe CLI** (`scribe chat`).

### 3. `runOneShot` — subagent / oneshot

One-shot JSON-in / JSON-out. Designed for a parent agent to spawn this agent
as a child process: the parent writes a `ScribeAgentRequest` to the child's
stdin and reads a `ScribeAgentResponse` from its stdout.

```swift
// In the subprocess:
let response = await agent.runIPC(
    request: ScribeAgentRequest(message: "Refactor the Router type."),
    onEvent: { _ in },    // events go to the subprocess log, not stdout
    log: logger
)
// response.ok → true/false
// response.assistant → final text
// response.error → error description if !ok
```

`ScribeAgentRequest` / `ScribeAgentResponse` are `Codable` — the parent agent
can serialize them over a pipe, an HTTP call, or any IPC transport.

Used by: recursive agent trees, tool-returned subagents, any orchestration
pattern where one agent delegates work to another.

## Tools

Built-in tools extend `ScribeTool`:

| Tool | Name | Description |
|------|------|-------------|
| `ShellTool` | `shell` | Run a shell command |
| `ReadFileTool` | `read_file` | Read a file with pagination |
| `WriteFileTool` | `write_file` | Create or overwrite a file |
| `EditFileTool` | `edit_file` | Find-and-replace in a file |

Custom tools conform to `ScribeTool` — four static properties (name, description,
parameters, optional promptHint) plus `func run(arguments:) async throws -> Encodable`.
