import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// MARK: - ProcessTreeReader

/// Reads the direct children of a process. Production implementations hit
/// `/proc` on Linux; tests inject a deterministic in-memory tree so the
/// recursive collection logic in `collectProcessTree` can be exercised on
/// macOS too (where the historical `setsid`-grandchild bugs are otherwise
/// unreproducible).
///
/// Returns `[]` when the pid has no recorded children, has exited, or
/// when the underlying source can't be read — callers treat all three the
/// same way (stop descending).
package protocol ProcessTreeReader: Sendable {
  func children(of pid: pid_t) -> [pid_t]
}

// MARK: - Tree walker

/// BFS-collects the descendants of `rootPid` using `reader`, returning the
/// root followed by every transitively-reachable child in discovery order.
///
/// Defensive bits worth knowing about:
/// - **Skips PIDs ≤ 2.** PID 1 is `init`/`launchd` and PID 2 is `kthreadd`
///   on Linux; signalling either is a recipe for taking the system down.
///   Production process trees never legitimately reach those, so a
///   misreported child of 0/1/2 is a sign the source is corrupt — drop it.
/// - **Cycle-resistant.** A child that's already in the result list is
///   skipped, so a circular `/proc` listing (we've seen reports during PID
///   wraparound) can't loop forever.
/// - **Pure function.** No side effects, no I/O of its own — entirely
///   testable on any platform with a stub `ProcessTreeReader`.
package func collectProcessTree(
  rootPid: pid_t,
  reader: any ProcessTreeReader
) -> [pid_t] {
  var pids: [pid_t] = [rootPid]
  var i = 0
  while i < pids.count {
    let current = pids[i]
    for child in reader.children(of: current) where child > 2 {
      if !pids.contains(child) {
        pids.append(child)
      }
    }
    i += 1
  }
  return pids
}

// MARK: - Linux /proc reader

#if os(Linux)
/// Reads child PIDs from `/proc/[pid]/task/[pid]/children`. The kernel
/// exposes a space-separated list there — empty when the process has no
/// children, missing entirely when the process has exited.
package struct ProcfsTreeReader: ProcessTreeReader {
  package init() {}
  package func children(of pid: pid_t) -> [pid_t] {
    let path = "/proc/\(pid)/task/\(pid)/children"
    guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
      return []
    }
    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    return trimmed.split(separator: " ").compactMap { pid_t($0) }
  }
}
#endif
