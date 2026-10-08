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

Run from the repository root:

**Linux**
```sh
swift package --package-path scribe-desktop chroma-install
```

**macOS**
```sh
swift package --package-path scribe-desktop --disable-sandbox \
  --allow-writing-to-directory "$HOME/Applications" chroma-install
```

Release builds include profiling symbols; pass `--without-profiling` to omit them.
Linux installs under `~/.local`; macOS installs `~/Applications/Scribe.app` and
requires an Apple Development signing identity. The macOS command disables SwiftPM's
plugin sandbox so signing can access the Keychain; only run it with packages you trust.
Quit Scribe before reinstalling. Recognized legacy Linux installs are migrated with
backups. No privileges are elevated.

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
Click **Sign in to Codex** in the app header and complete the browser login to
use ChatGPT/Codex. Signing in saves Scribe's credentials and adds a `codex`
profile to the config; choose it in the model picker. If authentication expires
or is revoked, sign in again and resend your message in the same session.
Scribe refreshes credentials during use and retries a rejected token once.

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

An optional `~/.scribe/system.md` replaces the built-in behavioral prompt for new sessions.
If the file is missing, Scribe uses its built-in prompt; an existing blank file also overrides it.
Tool hints, workspace context, and project instructions are appended in either case.
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
swift test --package-path scribe-desktop
swift run --package-path scribe-desktop scribe-mac
```

The root package contains only runtime libraries; `scribe-desktop` owns Chroma and the desktop app.

On Linux, use `swift run --package-path scribe-desktop scribe-wayland` instead.
See [DEVELOPMENT.md](DEVELOPMENT.md) for testing, profiling, logging, and embedding.

## Codex credential ownership

Standalone Scribe handles local Codex OAuth and refresh. Server broker networking,
transfer orchestration, device enrollment, and connection UI belong to ShapeTree.
Embedders use `LocalScribeSessionService` with a `CodexAccessCredentialProvider`.
See the [embedding recipe](DEVELOPMENT.md#embedding) for the recommended boundary.
