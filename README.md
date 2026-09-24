# Scribe

AI coding agent written in Swift, with macOS/Wayland apps.
Supports OpenAI-compatible providers and ChatGPT/Codex.

## Requirements

- macOS 27+ or Linux (x86_64/aarch64); Windows is unsupported.
- Swift tools 6.4+. Install [Swiftly](https://www.swift.org/install/), then run
  `swiftly install` to use the official Swift 6.4.0 release pinned in `.swift-version`.

Linux build dependencies:

```sh
sudo dnf install binutils file libcurl-devel libglvnd-devel libxkbcommon-devel pkgconf-pkg-config wayland-devel
```

Debian/Ubuntu:

```sh
sudo apt-get install binutils file libcurl4-openssl-dev libegl1-mesa-dev libgles2-mesa-dev libwayland-dev libxkbcommon-dev pkg-config
```

## Install

```sh
./Scripts/install.sh
```

- **macOS:** installs `/Applications/Scribe.app`; requires an Apple Development
  signing certificate. Override with `SCRIBE_CODESIGN_IDENTITY` and
  `SCRIBE_INSTALL_PATH`. Quit development instances and launch the installed
  copy with `open /Applications/Scribe.app` to keep permissions consistent.
- **Linux:** packages and installs to `~/.local`; override with `PREFIX`.
  Run `./Scripts/package-linux.sh` to create an archive only. Packaging uses
  SwiftPM's `native` engine to avoid a pinned-toolchain static-linking bug.

Use `./Scripts/install.sh --help` for overrides. No privileges are elevated automatically.

## Configuration

Config lookup: `SCRIBE_CONFIG_PATH`, `~/.scribe/scribe.config.json`, then
`./scribe.config.json`. If none exists, Scribe creates the default under
`~/.scribe`, targeting Ollama at `http://localhost:11434` with `gemma4:e2b`.
Set `SCRIBE_HOME` to change the data directory.

```json
{
  "profiles": [
    {
      "name": "local",
      "api": { "baseUrl": "http://localhost:11434", "apiKey": "" },
      "agent": { "model": "gemma4:e2b", "contextWindow": 128000 }
    }
  ]
}
```

The first profile is the default.
Set `api.type` to `"codex"` for ChatGPT/Codex, `"deepseek"` for DeepSeek-style
reasoning, or `"responses"` for a bearer-key Responses API; omit it for other
OpenAI-compatible chat completions APIs.
Optional agent settings: `contextWindowThreshold` (default `0.8`), `reasoning`
(`false`), `reasoningEffort`, `reasoningEfforts` (provider-supported values),
`serviceTier`, `serviceTiers` (supported values: `auto`, `default`, `flex`, `priority`),
and `maxRetries` (`3`).
Set `logging.level` to control verbosity (default `trace`).

Set `api.opencodeHeader` to `true` for OpenCode Go to send `x-opencode-session`
with the stable session ID on every request (default `false`).

Personal instructions go in `~/.scribe/system.md` and apply to new sessions only.
Sessions, metadata, and logs live in `~/.scribe/sessions/{uuid}/`.
Built-in tools: `shell`, `read_file`, `write_file`, and `edit_file`.

| Path | Default | Description |
|------|---------|-------------|
| `name` | *(required)* | Profile identifier; first profile is active by default |
| `api.baseUrl` | *(required)* | API base URL (e.g. `http://localhost:11434` for Ollama) |
| `api.apiKey` | `""` | Bearer token; leave empty when no auth is required |
| `api.type` | *(omitted)* | `"codex"` for ChatGPT/Codex, `"deepseek"` for DeepSeek-style reasoning, `"responses"` for a bearer-key Responses API (e.g. OpenCode Zen); omit for other chat completions providers |
| `agent.model` | *(required)* | Model name |
| `agent.contextWindow` | *(required)* | Token context window size |
| `agent.contextWindowThreshold` | `0.8` | Fraction (0–1) that triggers context compaction |
| `agent.reasoning` | `false` | Enable reasoning/thinking tokens for models that support it |
| `agent.reasoningEffort` | first listed, preferring `medium` | Initial reasoning effort |
| `agent.reasoningEfforts` | `[]` | Available levels shown in the model switcher, e.g. `["low", "medium", "high", "xhigh"]` |
| `agent.serviceTier` | first listed, preferring `default` | Initial API service tier |
| `agent.serviceTiers` | `[]` | Available service tiers shown in the model switcher, e.g. `["default", "priority"]` |
| `agent.maxTokens` | *(omitted)* | Reserved for provider-specific token limits |
| `agent.maxRetries` | `3` | Retries with exponential backoff on transient network failures (HTTP 429/5xx, dropped connections, timeouts); `0` disables |
| `logging.level` | `"trace"` | One of `trace`, `debug`, `info`, `notice`, `warning`, `error` |

> Scribe supports OpenAI-compatible chat completions, bearer-key Responses APIs,
> and `codex` (ChatGPT backend). For OpenCode Zen GPT models, use
> `"type": "responses"` with `"baseUrl": "https://opencode.ai/zen/v1"`.

## Development

```sh
swift build
swift test
swift run scribe-mac
```

On Linux, use `swift run scribe-wayland` instead.
See [DEVELOPMENT.md](DEVELOPMENT.md) for testing, profiling, logging, and embedding.
