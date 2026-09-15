import Foundation
import Logging
import Subprocess
import Synchronization

@testable import ScribeCore

final class SpyProcessKiller: ProcessKiller, Sendable {
  struct Invocation: Sendable {
    let rootPid: pid_t
    let shellID: UUID
  }

  private struct State {
    var invocations: [Invocation] = []
  }
  private let state = Mutex(State())
  private let forward = DefaultProcessKiller()

  init() {}

  func killTree(
    rootPid: pid_t,
    execution: ShellSubprocessExecution,
    logger: Logger,
    shellID: UUID
  ) -> Int {
    state.withLock { $0.invocations.append(.init(rootPid: rootPid, shellID: shellID)) }
    return forward.killTree(
      rootPid: rootPid, execution: execution, logger: logger, shellID: shellID)
  }

  func snapshot() -> [Invocation] {
    state.withLock { $0.invocations }
  }
}
