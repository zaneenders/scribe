# Scribe

Ai Agent written in Swift

## Install

### Requirements

- [Swift 6.3](https://www.swift.org/install/) or newer
- macOS 26+ or Linux (x86_64 or aarch64)
- For the graphical app/terminal on a fresh checkout: Zig 0.16.0+; macOS also
  needs `lipo` from Xcode command-line tools. Zig is only used once to generate
  the ignored libghostty-vt archive, or again when updating Ghostty.

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
git submodule update --init --recursive

./Scripts/bootstrap-zig.sh
swift package --allow-writing-to-package-directory --allow-network-connections all:443 refresh-ghostty-vt

# CLI
swift build -c release
install -m 755 .build/release/scribe ~/.local/bin/scribe

# Mac app (double-clickable, installable in /Applications)
swift package --allow-writing-to-package-directory bundle
rm -rf /Applications/Scribe.app
ditto dist/Scribe.app /Applications/Scribe.app
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

### Linux

Scribe's graphical app currently targets Wayland and uses Chroma's native
Wayland/EGL/OpenGL ES backend.

#### Build from source

Install Swift 6.3 and the native development packages first. Scribe's HTTP
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
git submodule update --init --recursive

# One-time terminal dependency build on a fresh checkout.
./Scripts/bootstrap-zig.sh
swift package --allow-writing-to-package-directory --allow-network-connections all:443 refresh-ghostty-vt

# Build a redistributable archive with CLI, app, desktop entry, and icon, then
# install it to ~/.local. The package script statically links the Swift runtime
# and rejects a build containing a machine-specific Swift runtime path.
./Scripts/package-linux.sh --install

# To create the archive under dist/ without installing it, omit --install.

# Or build and run only the app locally (Swift remains required in this case).
swift run -c release scribe-wayland
```

For CLI-only static builds, install the Swift static SDK once and build for your
architecture:

```bash
swift sdk install https://download.swift.org/swift-6.3.2-release/static-sdk/swift-6.3.2-RELEASE/swift-6.3.2-RELEASE_static-linux-0.1.0.artifactbundle.tar.gz \
  --checksum 3fd798bef6f4408f1ea5a6f94ce4d4052830c4326ab85ebc04f983f01b3da407

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
        // "type": "codex" | "kimi"   // omit for OpenAI-compatible providers
      },
      "agent": {
        "model": "gemma4:e2b",
        "contextWindow": 128000,
        "contextWindowThreshold": 0.8,
        "reasoning": false,
        // "reasoningEffort": "medium", // low | medium | high (reasoning models)
        // "maxTokens": 4096            // required for Kimi (max 4096)
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
| `api.type` | *(omitted)* | `"codex"` for ChatGPT/Codex, `"kimi"` for Kimi Code; omit for any OpenAI-compatible provider |
| `agent.model` | *(required)* | Model name |
| `agent.contextWindow` | *(required)* | Token context window size |
| `agent.contextWindowThreshold` | `0.8` | Fraction (0–1) that triggers context compaction |
| `agent.reasoning` | `false` | Enable reasoning/thinking tokens for models that support it |
| `agent.reasoningEffort` | *(omitted)* | Reasoning effort: `"low"`, `"medium"`, or `"high"` |
| `agent.maxTokens` | *(omitted)* | Max completion tokens; required for Kimi (4096 max) |
| `agent.maxRetries` | `3` | Retries with exponential backoff on transient network failures (HTTP 429/5xx, dropped connections, timeouts); `0` disables |
| `logging.level` | `"trace"` | One of `trace`, `debug`, `info`, `notice`, `warning`, `error` |

> Scribe supports OpenAI-compatible `completions` APIs, plus `codex` (ChatGPT
> backend) and `kimi` (Kimi Code) — set `api.type` to opt into non-standard
> providers.

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

## Ghostty terminal dependency

Ghostty source is pinned as the `Vendor/GhosttySource` Git submodule. Scribe
does not commit generated `libghostty-vt.a` archives. After a fresh recursive
clone, install the pinned project-local Zig toolchain and generate the platform
archive once:

```sh
./Scripts/bootstrap-zig.sh
swift package --allow-writing-to-package-directory refresh-ghostty-vt
```

Normal `swift build` calls only verify the archive exists and never invoke Zig.
If it is missing, the build prints the bootstrap command. Run the refresh again
when the Ghostty submodule is updated.

The public headers and third-party notices remain committed under
`Vendor/GhosttyVt` so API and license changes are reviewable. libghostty-vt is
MIT licensed; embedded dependency notices cover uucode, Höhrmann's UTF-8
decoder, and Unicode data. Detailed build, update, Linux, and provenance
instructions are in `Vendor/GhosttyVt/README.md`.
