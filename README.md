# Scribe

Ai Agent written in Swift

## Install

### Requirements

- [Swift tools 6.4](https://www.swift.org/install/) or newer
- macOS 26+ or Linux (x86_64 or aarch64)

Until a release toolchain is available, `.swift-version` pins
`main-snapshot-2026-09-10`, matching Chroma (the compiler identifies itself as
Swift 6.5-dev). Install and use it with [Swiftly](https://www.swift.org/install/):

```bash
swiftly install
swiftly run swift --version
swiftly run swift build
swiftly run swift test
```

With Swiftly's proxies on your `PATH`, the plain `swift` commands and build
scripts below select the pin automatically. The tools requirement is 6.4;
testing with this snapshot does not establish compatibility with a released
6.4 compiler.

On first run Scribe writes a default `scribe.config.json` targeting Ollama at
`http://localhost:11434` with the **`gemma4:e2b`** model.  Edit the file or set
`SCRIBE_CONFIG_PATH` to point to your own config.

Put the binary on your `PATH` (for example `~/.local/bin`):

```bash
# ensure ~/.local/bin is on your PATH
mkdir -p ~/.local/bin
```

### macOS

```bash
# CLI
swift build -c release
install -m 755 .build/release/scribe ~/.local/bin/scribe

# Mac app (build, stably sign, and install in /Applications)
./Scripts/install-macos.sh
```

Quit any development instance started with `swift run scribe-mac` before opening
the installed app. Launch the installed bundle explicitly after rebuilding:

```bash
open /Applications/Scribe.app
```

Using the explicit path prevents Launch Services from selecting the copy under
`dist/`, since both bundles have the same identifier. Removing the old app before
copying also prevents stale files from a previous bundle from surviving an
upgrade. The bundle embeds the CLI at `Scribe.app/Contents/Helpers/scribe` if you
prefer a single install artifact over a separate `~/.local/bin/scribe`.

The install script signs with the first **Apple Development** identity in your
login keychain. This gives Scribe a stable designated requirement so macOS keeps
its Accessibility and Screen Recording approvals across rebuilds. If you have
multiple matching identities, set one explicitly:

```bash
SCRIBE_CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)" \
  ./Scripts/install-macos.sh
```

Create an Apple Development certificate in Xcode if the script cannot find one.
Unlike the bundler's ad-hoc signature, a development-signed app's identity does
not change whenever its executable changes. Keep launching the installed copy at
the same path (`/Applications/Scribe.app`) rather than granting access separately
to `dist` or `swift run` builds.

### Linux

Scribe's graphical app currently targets Wayland and uses Chroma's native
Wayland/EGL/OpenGL ES backend.

#### Build from source

Install the Swift toolchain described above and the native development packages first. Scribe's HTTP
stack uses Swift's `FoundationNetworking` on Linux for `URLError` handling;
that module adds the `libcurl` linker dependency. The OpenAI-compatible and
Codex clients themselves send requests with AsyncHTTPClient.

On Fedora/RHEL (including Fedora Asahi Remix):

```bash
sudo dnf install binutils file libcurl-devel libglvnd-devel \
  libxkbcommon-devel pkgconf-pkg-config wayland-devel
```

On Debian/Ubuntu:

```bash
sudo apt-get install binutils file libcurl4-openssl-dev libegl1-mesa-dev \
  libgles2-mesa-dev libwayland-dev libxkbcommon-dev pkg-config
```

The `-devel`/`-dev` curl package is required when building even if the libcurl
runtime is already installed: it provides the unversioned `libcurl.so` linker
entry and `libcurl.pc` metadata. Installing a prebuilt Scribe archive only
requires the libcurl runtime package (`libcurl` on Fedora/RHEL or `libcurl4` on
Debian/Ubuntu), not the development package. Then build Scribe:

```bash
# Build a redistributable archive with CLI, app, desktop entry, and icon, then
# install it to ~/.local. The package script statically links the Swift runtime
# and rejects a build containing a machine-specific Swift runtime path.
./Scripts/package-linux.sh --install

# To create the archive under dist/ without installing it, omit --install.

# Or build and run only the app locally (Swift remains required in this case).
swift run -c release scribe-wayland
```

For CLI-only static builds, first install a Swift static Linux SDK matching
`swift --version`, using the download URL and checksum published for that
specific toolchain at [Swift.org](https://www.swift.org/install/). The old 6.3
SDK is not compatible with the pinned snapshot. If no matching SDK is available,
use the native Linux build above instead.

After installing the matching SDK, build for your architecture:

```bash
ARCH=$(uname -m)   # x86_64 or aarch64
swift build -c release --swift-sdk "${ARCH}-swift-linux-musl"
install -m 755 .build/release/scribe ~/.local/bin/scribe
```

### Windows 

Currently not supported, I would start with updating [slate](https://github.com/zaneenders/slate) to support a Windows terminal.

## Configuration

Scribe looks for `scribe.config.json` in this order:

1. `SCRIBE_CONFIG_PATH` environment variable (if set)
2. `~/.scribe/scribe.config.json`
3. `<cwd>/scribe.config.json`

If no config is found, a default is written to `~/.scribe/scribe.config.json` and loaded.

Set `SCRIBE_HOME` to override the `~/.scribe` data directory for config, logs, and sessions
(e.g. `SCRIBE_HOME=~/.local/share/scribe scribe`).

> `cwd` current working directory

### Configuration schema

The config file contains a `profiles` array — at least one profile is required.
Scribe uses the first profile by default; override with `--profile <name>`.

```jsonc
{
  "profiles": [
    {
      "name": "local",
      "api": {
        "baseUrl": "http://localhost:11434",
        "apiKey": "",
        // "type": "codex"   // omit for OpenAI-compatible providers
      },
      "agent": {
        "model": "gemma4:e2b",
        "contextWindow": 128000,
        "contextWindowThreshold": 0.8,
        "reasoning": false,
        // "reasoningEffort": "medium", // low | medium | high (reasoning models)
        // "maxTokens": 4096            // reserved for provider-specific limits
      },
      "logging": {
        "level": "trace"                // trace | debug | info | notice | warning | error
      }
    }
  ]
}
```

#### Profile fields

| Path | Default | Description |
|------|---------|-------------|
| `name` | *(required)* | Profile identifier; first profile is active by default |
| `api.baseUrl` | *(required)* | API base URL (e.g. `http://localhost:11434` for Ollama) |
| `api.apiKey` | `""` | Bearer token; leave empty when no auth is required |
| `api.type` | *(omitted)* | `"codex"` for ChatGPT/Codex; omit for any OpenAI-compatible provider |
| `agent.model` | *(required)* | Model name |
| `agent.contextWindow` | *(required)* | Token context window size |
| `agent.contextWindowThreshold` | `0.8` | Fraction (0–1) that triggers context compaction |
| `agent.reasoning` | `false` | Enable reasoning/thinking tokens for models that support it |
| `agent.reasoningEffort` | *(omitted)* | Reasoning effort: `"low"`, `"medium"`, or `"high"` |
| `agent.maxTokens` | *(omitted)* | Reserved for provider-specific token limits |
| `agent.maxRetries` | `3` | Retries with exponential backoff on transient network failures (HTTP 429/5xx, dropped connections, timeouts); `0` disables |
| `logging.level` | `"trace"` | One of `trace`, `debug`, `info`, `notice`, `warning`, `error` |

> Scribe supports OpenAI-compatible `completions` APIs, plus `codex` (ChatGPT
> backend) — set `api.type` to `"codex"` to use it.

## Tools

Scribe has four built-in tools: `shell`, `read_file`, `write_file`, `edit_file`.

## Sessions & Logs

Both are stored under `~/.scribe/` (or `$SCRIBE_HOME` if set):

```
~/.scribe/
├── scribe.config.json
└── sessions/{uuid}/
    ├── metadata.json
    ├── messages.jsonl
    └── scribe.log                       # diagnostic log for that session
```

Session names and pin state are stored in `metadata.json`. A session's default
name is its abbreviated hash (the first eight characters of its UUID). In the
graphical app, use **Rename** on a session row to assign a custom name; clearing
it restores the hash. Use **Pin** to keep a session above unpinned sessions in
the same workspace group.

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

### macOS app development

On macOS, `swift run scribe-mac`
launches an owned `--backend` subprocess on an ephemeral loopback port and connects
Chroma's `RemoteMetalClient` to it. The backend owns Scribe's block graph and
sessions; the client owns the native window and GPU. Closing the app stops its
backend. This is a local prototype, not an authenticated remote-access service.

Restart the development app after rebuilding; an already installed Scribe.app
will not pick up changes in either checkout.

Integration regression checks:

```sh
swift test --filter 'ScribeBlocksTests|ScribeMacLaunchTests'
(cd ../chroma && swift test --filter 'TrailingControlsRowTests|TextEventInterceptionTests|RemoteServerTests')
swift Scripts/test-backend-lifecycle.swift .build/debug/scribe-mac
```

The Swift launcher tests exercise readiness, early exit, malformed responses,
timeouts, normal EOF shutdown, and forced cleanup using small child processes.
The Swift smoke test exercises the actual headless backend, including parent
process death; it does not open a Metal window. Keyboard integration tests feed
portable key events through RemoteServer, not native AppKit event synthesis.
