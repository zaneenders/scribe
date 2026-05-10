# Scribe

Ai Agent written in Swift

## Install

The recommended setup is to clone Scribe into `~/.scribe/` so it shares the same root as
config, logs, and sessions — this lets Scribe find and modify its own source.

On first run Scribe writes a default `scribe-config.json` targeting Ollama at
`http://localhost:11434` with the **`gemma4:e2b`** model.  Edit the file or set
`SCRIBE_CONFIG_PATH` to point to your own config.

### MacOS

```bash
mkdir -p ~/.scribe
git clone https://github.com/zaneenders/scribe.git ~/.scribe/scribe
cd ~/.scribe/scribe
swift build -c release
sudo cp .build/release/scribe /usr/local/bin/scribe
```

### Linux

```bash
mkdir -p ~/.scribe
git clone https://github.com/zaneenders/scribe.git ~/.scribe/scribe
cd ~/.scribe/scribe
swift build -c release --swift-sdk x86_64-swift-linux-musl
sudo cp .build/release/scribe /usr/local/bin/scribe
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

**`shell`** runs commands via `/bin/sh -c`. Stdout and stderr are streamed to per-invocation
temp files (under the system temporary directory, e.g. `/tmp/` on Linux). The tool result
returns `stdoutFile` and `stderrFile` paths rather than inline output — the agent reads them
with `read_file` when it needs the contents. These temp files are not automatically cleaned
up; they persist until the system purges its temp directory (on reboot for Linux tmpfs, or
periodically on macOS).

## Sessions & Logs

Both are stored under `~/.scribe/` (or `$SCRIBE_HOME` if set):

```
~/.scribe/
├── scribe/                         # source clone (git clone ... ~/.scribe/scribe)
├── scribe-config.json
├── logs/scribe-{uuid}.log          # one log file per invocation
├── sessions/{uuid}/metadata.json   # one directory per session
└── sessions/{uuid}/messages.jsonl
```

## Info

Print Scribe's resolved paths and version:

```bash
scribe --info
```

## Testing

You can use the following commands to view current test coverage.

**macOS**
```bash
swift test --enable-code-coverage
PROFDATA=$(find .build -name '*.profdata' -print -quit)
BIN=$(find .build -name 'scribePackageTests' -type f -not -path '*.dSYM*' -print -quit)
xcrun llvm-cov report "$BIN" --instr-profile="$PROFDATA" --ignore-filename-regex='\.build/'
```

**Linux**
```bash
swift test --enable-code-coverage
PROFDATA=$(find .build -name '*.profdata' -print -quit)
BIN=$(find .build -name 'scribePackageTests.xctest' -type f -print -quit)
llvm-cov report "$BIN" --instr-profile="$PROFDATA" --ignore-filename-regex='\.build/'
```

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
