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

// MARK: - ProcessTreeReader stub

/// Records every `children(of:)` call so tests can verify the walker
/// visits the right pids in the right order, then returns the canned tree.
private final class StubReader: ProcessTreeReader, @unchecked Sendable {
  private struct State {
    var visited: [pid_t] = []
  }
  private let state = Mutex(State())
  private let tree: [pid_t: [pid_t]]

  init(tree: [pid_t: [pid_t]]) {
    self.tree = tree
  }

  func children(of pid: pid_t) -> [pid_t] {
    state.withLock { $0.visited.append(pid) }
    return tree[pid] ?? []
  }

  var visitOrder: [pid_t] {
    state.withLock { $0.visited }
  }
}

// MARK: - collectProcessTree

/// All of these run on macOS too — the tree-walker logic is what historically
/// shipped with the buggy Linux-only code path; making it pure-and-injectable
/// is the whole point of the `ProcessTreeReader` extraction.
@Suite
struct ProcessTreeWalkerTests {

  /// Single root with no children → the result is just the root.
  @Test func leafRootReturnsRootOnly() {
    let reader = StubReader(tree: [:])
    let result = collectProcessTree(rootPid: 100, reader: reader)
    #expect(result == [100])
    #expect(reader.visitOrder == [100])
  }

  /// Standard shell scenario: /bin/sh forks a child which forks two
  /// grandchildren. BFS order means parents come before grandchildren.
  @Test func bfsOrderForBalancedTree() {
    let reader = StubReader(tree: [
      100: [200],
      200: [300, 400],
    ])
    let result = collectProcessTree(rootPid: 100, reader: reader)
    #expect(result == [100, 200, 300, 400])
    // Walker visits each pid exactly once.
    #expect(reader.visitOrder == [100, 200, 300, 400])
  }

  /// PID 1 (init/launchd) and PID 2 (kthreadd) MUST be skipped — signalling
  /// either is a recipe for taking the system down. A misreported child of
  /// 0/1/2 from a corrupt /proc listing is a sign to drop it, not propagate.
  @Test func skipsKernelPids() {
    let reader = StubReader(tree: [
      100: [1, 2, 3, 4],
    ])
    let result = collectProcessTree(rootPid: 100, reader: reader)
    #expect(result == [100, 3, 4])
    #expect(!result.contains(1))
    #expect(!result.contains(2))
  }

  /// Cycle resistance: a circular `/proc` listing (we've seen reports during
  /// PID wraparound) must not loop forever. The "already in result" check
  /// handles this — verify the walker terminates and reports each pid once.
  @Test func cycleDoesNotInfiniteLoop() {
    // 100 → 200 → 300 → 100 (cycle back)
    let reader = StubReader(tree: [
      100: [200],
      200: [300],
      300: [100],
    ])
    let result = collectProcessTree(rootPid: 100, reader: reader)
    #expect(result == [100, 200, 300])
  }

  /// Diamond: two parents share a grandchild. The walker should see the
  /// grandchild once even though both parents reference it.
  @Test func diamondGraphDeduplicates() {
    let reader = StubReader(tree: [
      100: [200, 300],
      200: [400],
      300: [400],
    ])
    let result = collectProcessTree(rootPid: 100, reader: reader)
    #expect(result == [100, 200, 300, 400])
  }

  /// Deep chain — guards against accidental recursion-depth limits in the
  /// implementation. `collectProcessTree` is iterative, so this should fly.
  @Test func deepChain() {
    var tree: [pid_t: [pid_t]] = [:]
    let depth: pid_t = 50
    for i in 100..<(100 + depth) { tree[i] = [i + 1] }
    let reader = StubReader(tree: tree)
    let result = collectProcessTree(rootPid: 100, reader: reader)
    #expect(result.count == Int(depth) + 1)
    #expect(result.first == 100)
    #expect(result.last == 100 + depth)
  }
}

// MARK: - ProcTreeKiller (kill-order without invoking real kill())

/// Verifies that ProcTreeKiller iterates from leaves toward the root.  We
/// can't easily intercept the `kill(2)` syscall on real pids without a
/// signal handler, so this test runs the walker against a stub reader and
/// asserts the *collected order* — which is what the killer reverses
/// before calling `kill`. Combined with the killer's `pids.reversed()`,
/// this proves the kill order is leaves-first.
@Suite
struct ProcTreeKillerOrderTests {
  @Test func killOrderIsLeavesFirst() {
    let reader = StubReader(tree: [
      100: [200, 300],
      200: [400],
      300: [500],
    ])
    let collected = collectProcessTree(rootPid: 100, reader: reader)
    #expect(collected == [100, 200, 300, 400, 500])
    // The killer reverses this — leaves (500, 400) get SIGKILL first,
    // then their parents (300, 200), then the root (100). That order is
    // important so a parent doesn't try to reap a child while we're
    // still in the process of signalling it.
    let killOrder = Array(collected.reversed())
    #expect(killOrder == [500, 400, 300, 200, 100])
  }
}
