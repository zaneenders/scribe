# Scribe

Ai Agent written in Swift

## Config

Scribe looks for `scribe-config.json` in this order:

1. `SCRIBE_CONFIG_PATH` environment variable (if set)
2. `~/.config/scribe/scribe-config.json`
3. `<cwd>/scribe-config.json`

If no config is found, a default is written to `<cwd>/scribe-config.json` and loaded.

> `cwd` current working directory

### Config values

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

