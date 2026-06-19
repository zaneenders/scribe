import Foundation
import Logging
import Subprocess
import SystemPackage

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

package typealias ShellSubprocessExecution = Execution<NoInput, SequenceOutput, SequenceOutput>

package protocol ProcessKiller: Sendable {

  func killTree(
    rootPid: pid_t,
    execution: ShellSubprocessExecution,
    logger: Logger,
    shellID: UUID
  ) -> Int
}

extension ProcessKiller where Self == DefaultProcessKiller {

  package static var platformDefault: DefaultProcessKiller { DefaultProcessKiller() }
}

package struct DefaultProcessKiller: ProcessKiller {
  package init() {}

  package func killTree(
    rootPid: pid_t,
    execution: ShellSubprocessExecution,
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

package struct PgroupKiller: ProcessKiller {
  package init() {}

  package func killTree(
    rootPid: pid_t,
    execution: ShellSubprocessExecution,
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

    return 0
    #endif
  }
}

package struct ProcTreeKiller: ProcessKiller {
  let reader: any ProcessTreeReader

  package init(reader: any ProcessTreeReader) {
    self.reader = reader
  }

  package func killTree(
    rootPid: pid_t,
    execution: ShellSubprocessExecution,
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
