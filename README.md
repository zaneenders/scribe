# Scribe

Ai Agent written in Swift

## Configuration

Scribe looks for `scribe-config.json` in this order:

1. `SCRIBE_CONFIG_PATH` environment variable (if set)
2. `~/.config/scribe/scribe-config.json`
3. `<cwd>/scribe-config.json`

If no config is found, a default is written to `<cwd>/scribe-config.json` and loaded.

> `cwd` current working directory

### Configuration values

| Key | Description |
|-----|-------------|
| `api.baseUrl` | API base URL (e.g. `http://localhost:11434` for Ollama) |
| `api.apiKey` | Bearer token for the API; use `""` when no auth is required |
| `agent.model` | Model name (e.g. `gemma4:e2b`) |
| `agent.contextWindow` | Token context window size |
| `agent.contextWindowThreshold` | Fraction (0–1) that triggers context compaction |
| `logging.level` | One of `trace`, `debug`, `info`, `notice`, `warning`, `error` |
| `logging.storage` | Base directory for logs and sessions (`~/.local/share/scribe`) |


> Only OpenAI-compatible `completions` APIs are supported right now.

## Sessions & Logs

Both are stored under the directory set by `logging.storage` (default: `~/.local/share/scribe`):

```
~/.local/share/scribe/
├──logs/scribe-{uuid}.log         # one log file per invocation
├──sessions/{uuid}/metadata.json   # one directory per session
└──sessions/{uuid}/messages.jsonl
```

## Install 

You can install the binary anywhere but here is our recommendation.

### MacOS

```
swift build -c release
sudo mv .build/release/scribe ~/.local/bin/scribe
```

### Linux 

```
swift build -c release --swift-sdk x86_64-swift-linux-musl
sudo mv .build/release/scribe ~/.local/bin/scribe
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
BIN=$(find .build -name 'scribePackageTests' -type f -print -quit)
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

