# Plan: In-Process Profiling with Swift Profile Recorder

## Problem

Scribe is an async CLI agent that makes network calls, shells out to git and
other tools, and reads/writes files.  When latency or CPU spikes happen,
diagnosing _where_ time is spent requires tooling.  A sampling profiler that
runs inside the process (no `sudo`, no `CAP_SYS_PTRACE`) lets developers get
flamegraphs on-demand without leaving their normal workflow.

## Goal

Integrate [swift-profile-recorder](https://github.com/apple/swift-profile-recorder)
so that every `scribe` binary is profiling-capable the moment it starts — gated
entirely by an environment variable at runtime.

## Design

### Code changes

**File** | **Change**
---|---
`Package.swift` | Add `.package(url: "https://github.com/apple/swift-profile-recorder.git", .upToNextMinor(from: "0.3.13"))` and add `ProfileRecorderServer` product to `ScribeCLI` target.
`Sources/ScribeCLI/ScribeCLI.swift` | `import ProfileRecorderServer` and fire-and-forget `async let _ = ProfileRecorderServer(configuration: .parseFromEnvironment()).runIgnoringFailures(logger: log)` early in `run()`.

The profile recorder runs a tiny HTTP server on a UNIX domain socket.  When
the env var is absent it binds nothing and costs zero overhead beyond a single
`async let` task that immediately parks.

### Lifecycle

```
scribe starts
  → ConfigLoader.load()
  → ProfileRecorderServer.parseFromEnvironment()   // reads env, binds socket (or no-op)
  → async let _ = server.runIgnoringFailures(...)   // parked task, cancelled on exit
  → ... normal chat loop ...
  → run() returns → async let cancelled → socket torn down
```

Sampling is on-demand via `curl` against the socket.  No restart, no
recompilation, no elevated privileges.

### Sampling workflow

```bash
# 1. Start scribe with profiling enabled
PROFILE_RECORDER_SERVER_URL_PATTERN='unix:///tmp/scribe-{PID}.sock' \
  scribe

# 2. In another terminal, trigger a sample while scribe is doing work
curl --unix-socket /tmp/scribe-$(ls /tmp/scribe-*.sock | head -1 | sed 's/.*scribe-//;s/\.sock//').sock \
  -sd '{"numberOfSamples":200,"timeInterval":"10ms"}' \
  http://localhost/sample > ./samples.perf

# 3. Visualize: drag ./samples.perf onto https://speedscope.app
```

**Key parameters:**

- `numberOfSamples` — how many stacks to capture (200 = ~2 seconds at 10 ms intervals)
- `timeInterval` — sampling interval, e.g. `"10ms"` or `"100ms"`.  Shorter = more granular, longer = less overhead during sampling.

### Release build frame pointers

The sampler walks stacks via frame pointers.  Swift debug builds keep them;
release builds may omit them.  For profiling release builds, add to
`ScribeCLI`'s `swiftSettings`:

```swift
.unsafeFlags(["-Xcc", "-fno-omit-frame-pointer"]),
```

(Flag can be scoped behind `#if hasAttribute(profile)` or a dedicated
`--profile` build configuration later if needed.)

### What to profile

| Scenario | What to look for |
|---|---|
| Slow chat response | Is time in network I/O, LLM token processing, or tool execution? |
| Tool latency | `ShellTool` vs `ReadFileTool` vs `EditFileTool` — which dominates? |
| Startup time | Where does `ConfigLoader.load()` or session resume spend cycles? |
| High CPU during idle | Any unexpected busy-looping (e.g. NIO event loop spinning)? |
| Large repo operations | `git status`, `git diff`, grep — are we shelling out inefficiently? |

## Risks / unknowns

1. **macOS frame pointers**: Swift release builds on macOS may strip frame
   pointers.  The `-fno-omit-frame-pointer` flag is the fix, but it subtly
   changes optimization.  Profile both with and without to confirm the
   overhead is negligible (typically < 1%).

2. **Socket lifecycle**: The `async let` task is cancelled when `run()`
   returns.  Confirm the socket file at `/tmp/scribe-{PID}.sock` is cleaned
   up on exit (the profile recorder uses `NIO` and should unlink it).

3. **Swift 6 strict concurrency**: Profile recorder enables
   `StrictConcurrency=complete` on its targets.  Scribe does too.  No
   expected conflicts, but this is the first third-party dep that ships
   with the same strictness, so worth a `swift build` smoke test.

## Implementation order

1. Add the Package.swift dependency and product.
2. Add the 3-line integration to `ScribeCLI.swift`.
3. Build and smoke test: `PROFILE_RECORDER_SERVER_URL_PATTERN=... scribe`
   then `curl` the sample endpoint.
4. Document the workflow in `README.md` or a `docs/profiling.md` user guide.
