import Foundation
import Logging
import Subprocess

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// MARK: - ProcessKiller

/// Strategy that terminates the process tree spawned by a single shell
/// invocation. Different platforms need different approaches:
///
/// - **macOS / *BSD**: `kill(-pgid, SIGKILL)` via subprocess. This catches
///   anything that stayed in the original process group, but **misses
///   `setsid` grandchildren** that escaped into a new session. macOS
///   doesn't expose a process-children syscall in the same convenient way
///   `/proc/<pid>/children` does on Linux, so this is the best we have
///   short of pulling in a libproc dependency.
/// - **Linux**: walks the process tree via `/proc` and SIGKILLs leaves
///   first. Catches `setsid` escapees that the simple pgroup kill would
///   miss — see `ProcfsTreeReader`.
/// - **Windows**: delegates to `subprocess.terminate(...)`.
///
/// The protocol exists primarily to let tests on macOS exercise the
/// Linux-style tree-walk logic against a stub reader. Production code
/// gets the right strategy via `ProcessKiller.platformDefault`.
package protocol ProcessKiller: Sendable {
  /// Synchronously kill the process tree rooted at `rootPid`. Implementations
  /// MUST be safe to call from a `withTaskCancellationHandler`'s
  /// `onCancel:` block, which means: no `await`, no allocations of
  /// async resources, and idempotency on repeated invocation.
  ///
  /// `execution` is provided so platform-specific strategies that delegate
  /// to swift-subprocess (macOS pgroup kill, Windows terminate) can do so
  /// without re-deriving the handle from `rootPid`.
  ///
  /// Returns the number of processes that were successfully signalled
  /// (root included). Mostly informational — used in trace logs to spot
  /// missed grandchildren.
  func killTree(
    rootPid: pid_t,
    execution: Subprocess.Execution,
    logger: Logger,
    shellID: UUID
  ) -> Int
}

extension ProcessKiller where Self == DefaultProcessKiller {
  /// The platform-appropriate default strategy. Wraps either pgroup kill
  /// (macOS / Windows) or the `/proc`-walking tree kill (Linux).
  package static var platformDefault: DefaultProcessKiller { DefaultProcessKiller() }
}

// MARK: - DefaultProcessKiller

/// Resolves to the right platform strategy at compile time.  Kept as a
/// concrete type rather than a typealias so callers can always say
/// `ProcessKiller.platformDefault` without importing the underlying type.
package struct DefaultProcessKiller: ProcessKiller {
  package init() {}

  package func killTree(
    rootPid: pid_t,
    execution: Subprocess.Execution,
    logger: Logger,
    shellID: UUID
  ) -> Int {
    #if os(Windows)
    do {
      logger.trace(
        "shell-kill-windows-terminate",
        metadata: ["shell_id": "\(shellID)", "pid": "\(rootPid)"])
      try execution.terminate(withExitCode: 0)
      return 1
    } catch {
      logger.trace(
        "shell-kill-windows-terminate-failed",
        metadata: [
          "shell_id": "\(shellID)", "pid": "\(rootPid)",
          "error": "\(String(describing: error))",
        ])
      return 0
    }
    #elseif os(Linux)
    return ProcTreeKiller(reader: ProcfsTreeReader()).killTree(
      rootPid: rootPid, execution: execution, logger: logger, shellID: shellID)
    #else
    return PgroupKiller().killTree(
      rootPid: rootPid, execution: execution, logger: logger, shellID: shellID)
    #endif
  }
}

// MARK: - PgroupKiller (macOS / *BSD)

/// `kill(-pgid, SIGKILL)` via swift-subprocess. Catches the foreground
/// process group; misses `setsid` grandchildren — but the process-group
/// strategy is what swift-subprocess offers natively, and `setsid`
/// escapees are rare enough on macOS that going to libproc isn't worth it.
package struct PgroupKiller: ProcessKiller {
  package init() {}

  package func killTree(
    rootPid: pid_t,
    execution: Subprocess.Execution,
    logger: Logger,
    shellID: UUID
  ) -> Int {
    #if !os(Windows)
    do {
      logger.trace(
        "shell-kill-pgrp",
        metadata: ["shell_id": "\(shellID)", "pid": "\(rootPid)"])
      try execution.send(signal: .kill, toProcessGroup: true)
      return 1
    } catch {
      logger.trace(
        "shell-kill-pgrp-failed",
        metadata: [
          "shell_id": "\(shellID)", "pid": "\(rootPid)",
          "error": "\(String(describing: error))",
        ])
      return 0
    }
    #else
    // On Windows the protocol shouldn't be reaching this branch (DefaultProcessKiller
    // routes to terminate), but the file compiles on every platform so keep
    // a no-op fallback rather than failing the build.
    return 0
    #endif
  }
}

// MARK: - ProcTreeKiller (Linux)

/// Walks the process tree via a `ProcessTreeReader` and SIGKILLs from the
/// leaves toward the root. Catches `setsid` grandchildren that the
/// pgroup-kill strategy would miss.
///
/// The walker logic is a pure function (`collectProcessTree`) and the
/// reader is injectable, so this strategy is fully unit-testable on any
/// platform — feed it a stub tree and verify the right pids are signalled
/// in the right order. The actual `kill(2)` syscall on real pids still
/// requires Linux for end-to-end coverage.
package struct ProcTreeKiller: ProcessKiller {
  let reader: any ProcessTreeReader

  package init(reader: any ProcessTreeReader) {
    self.reader = reader
  }

  package func killTree(
    rootPid: pid_t,
    execution: Subprocess.Execution,
    logger: Logger,
    shellID: UUID
  ) -> Int {
    let pids = collectProcessTree(rootPid: rootPid, reader: reader)
    logger.trace(
      "shell-kill-tree-collected",
      metadata: [
        "shell_id": "\(shellID)", "root_pid": "\(rootPid)",
        "total_pids": "\(pids.count)",
        "pids": "\(pids.map { String($0) }.joined(separator: ","))",
      ])
    var killed = 0
    #if !os(Windows)
    for victim in pids.reversed() {
      if Foundation_kill(victim, SIGKILL) == 0 {
        killed += 1
      } else {
        let e = errno
        if e != ESRCH {
          logger.trace(
            "shell-kill-tree-single-failed",
            metadata: [
              "shell_id": "\(shellID)", "pid": "\(victim)", "errno": "\(e)",
            ])
        }
      }
    }
    #endif
    return killed
  }
}

// `kill` from libc collides with `Subprocess.send(signal:)` if both are in
// scope unqualified, so re-export under a name nobody else uses.
#if canImport(Darwin)
@inline(__always)
private func Foundation_kill(_ pid: pid_t, _ sig: Int32) -> Int32 {
  Darwin.kill(pid, sig)
}
#elseif canImport(Glibc)
@inline(__always)
private func Foundation_kill(_ pid: pid_t, _ sig: Int32) -> Int32 {
  Glibc.kill(pid, sig)
}
#elseif canImport(Musl)
@inline(__always)
private func Foundation_kill(_ pid: pid_t, _ sig: Int32) -> Int32 {
  Musl.kill(pid, sig)
}
#endif
