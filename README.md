# Scribe

Ai Agent written in Swift

## Install

### Requirements

- [Swift 6.3](https://www.swift.org/install/) or newer
- macOS 26+ or Linux (x86_64 or aarch64)

Clone Scribe into `~/.scribe/scribe` so it shares the same root as config, logs, and
sessions — this lets Scribe find and modify its own source.

On first run Scribe writes a default `scribe-config.json` targeting Ollama at
`http://localhost:11434` with the **`gemma4:e2b`** model.  Edit the file or set
`SCRIBE_CONFIG_PATH` to point to your own config.

Put the binary on your `PATH` (for example `~/.local/bin`):

```bash
# ensure ~/.local/bin is on your PATH
mkdir -p ~/.local/bin
```

### macOS

```bash
mkdir -p ~/.scribe
git clone https://github.com/zaneenders/scribe.git ~/.scribe/scribe
cd ~/.scribe/scribe
swift build -c release
install -m 755 .build/release/scribe ~/.local/bin/scribe
```

### Linux

Install the Swift static SDK once, then build for your architecture:

```bash
swift sdk install https://download.swift.org/swift-6.3.2-release/static-sdk/swift-6.3.2-RELEASE/swift-6.3.2-RELEASE_static-linux-0.1.0.artifactbundle.tar.gz \
  --checksum 3fd798bef6f4408f1ea5a6f94ce4d4052830c4326ab85ebc04f983f01b3da407

mkdir -p ~/.scribe
git clone https://github.com/zaneenders/scribe.git ~/.scribe/scribe
cd ~/.scribe/scribe
ARCH=$(uname -m)   # x86_64 or aarch64
swift build -c release --swift-sdk "${ARCH}-swift-linux-musl"
install -m 755 .build/release/scribe ~/.local/bin/scribe
```

### Windows 

Currently not supported, I would start with updating [slate](https://github.com/zaneenders/slate) to support a Windows terminal.

## Configuration

Scribe looks for `scribe-config.json` in this order:

1. `SCRIBE_CONFIG_PATH` environment variable (if set)
2. `~/.scribe/scribe-config.json`
3. `<cwd>/scribe-config.json`

If no config is found, a default is written to `~/.scribe/scribe-config.json` and loaded.

Set `SCRIBE_HOME` to override the `~/.scribe` data directory for config, logs, and sessions
(e.g. `SCRIBE_HOME=~/.local/share/scribe scribe`).

> `cwd` current working directory

### Configuration values

| Key | Default | Description |
|-----|---------|-------------|
| `api.baseUrl` | `http://localhost:11434` | API base URL (Ollama default) |
| `api.apiKey` | `""` | Bearer token; leave empty when no auth is required |
| `agent.model` | `gemma4:e2b` | Model name |
| `agent.contextWindow` | `128000` | Token context window size |
| `agent.contextWindowThreshold` | `0.8` | Fraction (0–1) that triggers context compaction |
| `logging.level` | `trace` | One of `trace`, `debug`, `info`, `notice`, `warning`, `error` |

> Only OpenAI-compatible `completions` APIs are supported right now.

## Tools

Scribe has four built-in tools: `shell`, `read_file`, `write_file`, `edit_file`.

## Sessions & Logs

Both are stored under `~/.scribe/` (or `$SCRIBE_HOME` if set):

```
~/.scribe/
├── scribe/                              # source clone (git clone ... ~/.scribe/scribe)
├── scribe-config.json
└── sessions/{uuid}/
    ├── metadata.json
    ├── messages.jsonl
    └── scribe.log                       # diagnostic log for that session
```

Per-session logs live under `sessions/{uuid}/scribe.log`. Older releases wrote
`~/.scribe/logs/scribe-{uuid}.log`; those files are not moved automatically.

### Embedding ScribeCore

When building on ``ScribeAgent`` directly (server, tests, custom CLI):

- Pass a host-owned `Logger` into ``ScribeAgent`` at init; it flows through the agent loop and built-in tools.
- ``ToolRegistry`` requires `init(tools:logger:)`.
- ``ToolExecutor/execute`` takes `logger:` for each invocation.
- The global `ScribeCore.scribeSessionLogger` sink was removed — inject your own logger instead.

See `DEVELOPMENT.md` (Logging) for line format and message conventions.

## Documentation

Preview generated documentation with Swift DocC (included in the Swift toolchain):

### Core
```bash
docc preview Sources/ScribeCore/ScribeCore.docc
```

### CLI
```bash
docc preview Sources/ScribeCLI/ScribeCLI.docc
```
