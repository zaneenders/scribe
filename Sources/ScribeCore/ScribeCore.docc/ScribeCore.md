# ScribeCore

The Scribe agent library — model orchestration, tool execution, and session management.

## Logging

Embedders must supply a [swift-log](https://github.com/apple/swift-log) ``Logger`` when constructing ``ScribeAgent``. That logger is passed through the agent loop, ``ToolRegistry``, and each ``ToolExecutor/execute`` call.

There is no package-level session logger; do not expect ScribeCore to open log files for you.

### API changes

| Before | After |
|--------|--------|
| Optional implicit logging via `ScribeCore.scribeSessionLogger` | Removed — inject `logger:` at ``ScribeAgent`` init |
| `ToolRegistry(tools:)` | `ToolRegistry(tools:logger:)` |
| `ToolExecutor.execute(…, abort:)` | `ToolExecutor.execute(…, logger:, abort:)` |

Log messages use `domain.action` strings (e.g. `agent.tool.start`) with structured swift-log `metadata`.
