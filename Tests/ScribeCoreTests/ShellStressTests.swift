import Foundation
import Synchronization
import Testing

@testable import ScribeCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// MARK: - Stress test

/// Stress harness for `Shell.run` + cancellation. The historical bug being
/// guarded against was a 100% CPU spin under "user mashes Ctrl+C against a
/// chatty shell" workloads — caused by some combination of an unstructured
/// orphan `Task` per cancellation, a per-write `fsync` in the file-sink
/// logger, and `for try await` blocked on a pipe whose draining stopped
/// after a write failure (suspects A, C, D in the report).
///
/// This suite is the lock-in: a tight loop of "spawn a chatty shell,
/// cancel mid-flight, wait for it to settle" that watches three things:
///
/// 1. **Open-FD growth.** Reads `/dev/fd` (macOS) or `/proc/self/fd`
///    (Linux) before/after the loop and asserts no descriptors leaked.
///    This is the most direct catch for the FD-leak class of bug.
/// 2. **CPU time.** `getrusage(RUSAGE_SELF)` before/after; asserts the
///    process didn't burn an unreasonable amount of CPU per iteration.
///    Generous bound — we're only catching "spinning" (≥80% of wall
///    clock), not optimising.
/// 3. **Wall time.** Each cancelled run has to settle in a bounded
///    window — guards against a regression that would let a stuck
///    drain hang the test indefinitely.
@Suite
struct ShellStressTests {

  /// Run a 1-second-output shell command 20 times, cancelling each one
  /// after 50ms. Asserts:
  ///   - Every iteration completes within 3s wall.
  ///   - Total user+sys CPU is < 80% of total wall (i.e. not pegging).
  ///   - Open-FD count after equals open-FD count before.
  @Test func loopedCancelsDoNotLeakFDsOrPegCPU() async throws {
    let iterations = 20
    let beforeFDs = Self.openFDCount()
    let beforeCPU = Self.cpuTime()
    let wallStart = ContinuousClock.now

    for i in 0..<iterations {
      let task = Task {
        // 1000 iterations × 1ms sleep = ~1s of constant chatter on stdout.
        // Plenty for the drain to engage; cancel hits well before EOF.
        try await Shell.run(
          command:
            "i=0; while [ $i -lt 1000 ]; do echo line$i; i=$((i+1)); sleep 0.001; done",
          cwd: nil,
          workingDirectory: ScribeFilePath("/tmp"))
      }
      try await Task.sleep(for: .milliseconds(50))
      task.cancel()

      let iterStart = ContinuousClock.now
      _ = try? await task.value
      let iterElapsed = iterStart.duration(to: .now)
      #expect(
        iterElapsed < .seconds(3),
        "iteration \(i) took \(iterElapsed) — drain should settle within 3s")
    }

    let wallElapsed = wallStart.duration(to: .now)
    let afterCPU = Self.cpuTime()
    let afterFDs = Self.openFDCount()

    let cpuDelta = afterCPU - beforeCPU
    let wallSeconds = Double(wallElapsed.components.seconds)
      + Double(wallElapsed.components.attoseconds) / 1e18
    let cpuRatio = wallSeconds > 0 ? cpuDelta / wallSeconds : 0

    // FD leak: zero-tolerance. The drain has to close its handles on
    // every cancellation path (drain-completed, deadline-fired, or
    // error). Anything else and the bug is back.
    if beforeFDs > 0 && afterFDs > 0 {
      // Slack of 5 — Foundation/swift-log can open descriptors lazily on
      // first use during the loop (e.g. the first time the file-handle
      // logging path lands), and a few platform internals do too. The
      // historical FD leak under repeat Ctrl-C was 2 FDs per shell ×
      // 20 iterations = +40, well outside this slack.
      #expect(
        afterFDs <= beforeFDs + 5,
        "open FD count grew from \(beforeFDs) to \(afterFDs) over \(iterations) cancelled shells — possible FD leak")
    }

    // CPU pegging: very generous bound. Real runs sit around 10-30%
    // (subprocess overhead). The historical spin was ≥90% sustained;
    // 80% catches that without flaking on CI.
    #expect(
      cpuRatio < 0.8,
      "CPU usage was \(String(format: "%.0f%%", cpuRatio * 100)) of wall time over \(iterations) cancelled shells — possible CPU spin (cpu=\(cpuDelta)s wall=\(wallSeconds)s)")
  }

  // MARK: - getrusage / FD helpers

  /// Returns total user + system CPU consumed by *this* process (seconds).
  /// `RUSAGE_SELF` covers all threads, which is what we want — the spin
  /// might happen on a worker thread, not the test main thread.
  private static func cpuTime() -> Double {
    var ru = rusage()
    _ = getrusage(RUSAGE_SELF, &ru)
    let user = Double(ru.ru_utime.tv_sec) + Double(ru.ru_utime.tv_usec) / 1_000_000.0
    let system = Double(ru.ru_stime.tv_sec) + Double(ru.ru_stime.tv_usec) / 1_000_000.0
    return user + system
  }

  /// Best-effort open-FD count. Returns -1 on platforms where neither
  /// listing is readable so the caller can skip the assertion.
  private static func openFDCount() -> Int {
    let candidates = ["/dev/fd", "/proc/self/fd"]
    for path in candidates {
      if let entries = try? FileManager.default.contentsOfDirectory(atPath: path) {
        return entries.count
      }
    }
    return -1
  }
}
