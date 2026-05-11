# Development

## Requirements

Until a 1.0.0 release the project targets the latest Swift version only.

Currently only working on MacOs and Linux support so Windows is not currently
supported but contributions and maintainers for that effort are welcome.

## `.dev` directory

`.dev/` holds the north star for each active effort — a living design doc that
describes the target and evolves alongside implementation. Once shipped, its
content is absorbed into permanent documentation (inline doc comments surfaced
by [Swift DocC][docc], `README.md`, etc.) and the `.dev/` file is removed.

[docc]: https://www.swift.org/documentation/docc/

## Testing

You can use the following commands to view current test coverage.

**macOS**
```bash
swift test --enable-code-coverage
PROFDATA=$(find .build -name '*.profdata' -print -quit)
BIN=$(find .build -name 'scribePackageTests' -type f -not -path '*.dSYM*' -print -quit)
xcrun llvm-cov report "$BIN" --instr-profile="$PROFDATA" --ignore-filename-regex='(\.build/|Tests/)'
```

**Linux**
```bash
swift test --enable-code-coverage
PROFDATA=$(find .build -name '*.profdata' -print -quit)
BIN=$(find .build -name 'scribePackageTests.xctest' -type f -print -quit)
llvm-cov report "$BIN" --instr-profile="$PROFDATA" --ignore-filename-regex='(\.build/|Tests/)'
```

## Profiling

Scribe has [swift-profile-recorder](https://github.com/apple/swift-profile-recorder)
built in — an in-process sampling profiler gated by an environment variable.
No `sudo`, no `CAP_SYS_PTRACE`, no restart needed.

### Setup

The profiler starts when `PROFILE_RECORDER_SERVER_URL_PATTERN` is set at
launch time. It binds a tiny HTTP server on a UNIX domain socket. Without
the env var, there is zero overhead.

```bash
PROFILE_RECORDER_SERVER_URL_PATTERN='unix:///tmp/scribe-{PID}.sock' scribe
```

> you may append `scribe` with something like `swift build -c release` if you want to profile a version you are building.

The `{PID}` template is replaced with the process ID at runtime.

### Capturing a profile

While scribe is doing work, trigger a sample from another terminal:

```bash
curl --unix-socket /tmp/scribe-$(ls /tmp/scribe-*.sock | head -1 | sed 's/.*scribe-//;s/\.sock//').sock \
  -sd '{"numberOfSamples":500,"timeInterval":"10ms"}' \
  http://localhost/sample > ./samples.perf
```

**Parameters:**

| Key | Description |
|---|---|
| `numberOfSamples` | How many stacks to capture (500 ≈ 5 seconds at 10 ms intervals) |
| `timeInterval` | Sampling interval, e.g. `"10ms"` or `"100ms"` |

**Choosing parameters:**

- `"10ms"` (100 Hz) is a good default — fine-grained enough to see hot paths,
  coarse enough to avoid excessive overhead.
- `numberOfSamples` controls duration: 500 samples at 10ms = 5 seconds,
  2000 at 10ms = 20 seconds. Start with 500; increase if you need a longer
  window to catch sporadic work.
- The profiler captures **all threads**. You'll see NIO event loops and GCD
  worker threads even when the app is idle, so trigger the capture while the
  app is actively doing the work you want to profile — not when it's sitting
  at a prompt.
- A 500-sample profile at 10ms produces a ~5 MB file. Scaling to 100,000
  samples produces unwieldy ~100 MB files that are mostly idle-thread noise.

### Visualizing

Drag `./samples.perf` onto [speedscope.app](https://speedscope.app).

### What to profile

| Scenario | What to look for |
|---|---|
| Slow chat response | Time in network I/O, LLM token processing, or tool execution? |
| Tool latency | `ShellTool` vs `ReadFileTool` vs `EditFileTool` — which dominates? |
| Startup time | Where does `ConfigLoader.load()` or session resume spend cycles? |
| High CPU at idle | Any unexpected busy-looping (e.g. NIO event loop spinning)? |
| Large repo operations | `git status`, `git diff`, grep — are we shelling out inefficiently? |

### Release builds

Release builds omit frame pointers by default, which breaks stack walking.
The `ScribeCLI` target already includes `-Xcc -fno-omit-frame-pointer` so
release-mode profiling works out of the box.

