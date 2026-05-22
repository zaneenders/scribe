import SystemPackage
import Foundation
import Logging
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

/// Stress harness for `Shell.run` + cancellation. The historical bug
/// being guarded against was a 100% CPU spin under "user mashes Ctrl+C
/// against a chatty shell" workloads — caused by some combination of an
/// unstructured orphan `Task` per cancellation, a per-write `fsync` in
/// the file-sink logger, and `for try await` blocked on a pipe whose
/// draining stopped after a write failure (suspects A, C, D).
///
/// **What this test actually asserts** (and what it doesn't):
///
/// - **Wall-time bound per iteration.** A spinning process never
///   completes; a 50 ms cancel against a 1 s chatty loop has to settle
///   in well under 3 s. This is the *strong* regression guard — the
///   historical bug was unbounded in time, so any wall-time bound
///   catches it.
/// - **FD growth doesn't scale catastrophically.** Allows up to ~8 FDs
///   per iteration of slack: enough to tolerate "swift-subprocess /
///   FileHandle close lazily on Linux" patterns we don't yet fully
///   understand, but tight enough that a real "leak N temp files per
///   shell" regression would fail. The historical bug here would have
///   leaked dozens of FDs per iteration, well past this bound.
/// - **CPU time per iteration is bounded.** Not as a ratio of wall
///   clock (a multi-core box with concurrent drain tasks can legitimately
///   exceed 100% of wall) but as an absolute "no shell should burn more
///   than 1 s of CPU when we cancel after 50 ms of work." That cap
///   would still catch a single-core spin (which is what the historical
///   bug was) without flaking on Linux's multi-threaded executor.
///
/// On Linux we currently observe ~4 FDs of growth per cancelled shell.
/// That's worth investigating separately — it suggests
/// swift-subprocess or `FileHandle`'s deinit-driven cleanup runs after
/// the test concludes — but it's not the same class of bug as the CPU
/// spin and shouldn't gate the regression check here.
@Suite
struct ShellStressTests {

  @Test func loopedCancelsDoNotLeakFDsOrPegCPU() async throws {
    let iterations = 20
    let beforeFDs = Self.openFDCount()
    let beforeCPU = Self.cpuTime()

    for i in 0..<iterations {
      let task = Task {
        // 1000 iterations × 1ms sleep = ~1s of constant chatter on stdout.
        // Plenty for the drain to engage; cancel hits well before EOF.
        try await Shell.run(
          command:
            "i=0; while [ $i -lt 1000 ]; do echo line$i; i=$((i+1)); sleep 0.001; done",
          cwd: nil,
          workingDirectory: FilePath("/tmp"), logger: toolRunnerTestLogger)
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

    let afterCPU = Self.cpuTime()
    let afterFDs = Self.openFDCount()

    let cpuDelta = afterCPU - beforeCPU

    // FD growth — bounded per iteration, not absolute. 8 FDs/iter of
    // slack covers the worst observed pattern (stdout pipe + stderr
    // pipe + 2 temp-file handles, possibly with deferred close) with
    // headroom. A regression that leaks dozens per shell would still
    // fail this. Skip if the platform doesn't expose an FD listing.
    if beforeFDs > 0 && afterFDs > 0 {
      let maxAllowedGrowth = 8 * iterations + 20
      #expect(
        afterFDs - beforeFDs <= maxAllowedGrowth,
        "open FD count grew from \(beforeFDs) to \(afterFDs) (+\(afterFDs - beforeFDs)) over \(iterations) cancelled shells — bound \(maxAllowedGrowth)"
      )
    }

    // CPU bound — absolute, per-iteration, not a wall-clock ratio. The
    // historical spin was a single core pegged forever after cancellation;
    // 50 ms of real work per shell should never burn more than 1 s of
    // CPU even on a slow box. A ratio against wall clock would flake on
    // multi-core Linux where genuine concurrent drain work easily
    // exceeds 100%.
    let cpuBudgetPerShell = 1.0
    let totalCpuBudget = Double(iterations) * cpuBudgetPerShell
    #expect(
      cpuDelta < totalCpuBudget,
      "consumed \(String(format: "%.2fs", cpuDelta)) of CPU over \(iterations) cancelled shells (budget \(String(format: "%.2fs", totalCpuBudget))) — possible CPU spin"
    )
  }

  // MARK: - getrusage / FD helpers

  /// Returns total user + system CPU consumed by *this* process across
  /// all threads (seconds). Used for absolute "CPU per iteration"
  /// bounds, not as a wall-clock ratio.
  ///
  /// `RUSAGE_SELF` imports as a plain `Int32` on Darwin but as the
  /// `__rusage_who` enum on glibc/musl, so we normalise to `Int32` at
  /// the call site rather than letting the type mismatch break Linux.
  private static func cpuTime() -> Double {
    #if canImport(Darwin)
    let who: Int32 = RUSAGE_SELF
    #else
    let who = Int32(RUSAGE_SELF.rawValue)
    #endif
    var ru = rusage()
    _ = getrusage(who, &ru)
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
