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

@Suite
struct ProcessTreeWalkerTests {

  @Test func leafRootReturnsRootOnly() {
    let reader = StubReader(tree: [:])
    let result = collectProcessTree(rootPid: 100, reader: reader)
    #expect(result == [100])
    #expect(reader.visitOrder == [100])
  }

  @Test func bfsOrderForBalancedTree() {
    let reader = StubReader(tree: [
      100: [200],
      200: [300, 400],
    ])
    let result = collectProcessTree(rootPid: 100, reader: reader)
    #expect(result == [100, 200, 300, 400])

    #expect(reader.visitOrder == [100, 200, 300, 400])
  }

  @Test func skipsKernelPids() {
    let reader = StubReader(tree: [
      100: [1, 2, 3, 4]
    ])
    let result = collectProcessTree(rootPid: 100, reader: reader)
    #expect(result == [100, 3, 4])
    #expect(!result.contains(1))
    #expect(!result.contains(2))
  }

  @Test func cycleDoesNotInfiniteLoop() {

    let reader = StubReader(tree: [
      100: [200],
      200: [300],
      300: [100],
    ])
    let result = collectProcessTree(rootPid: 100, reader: reader)
    #expect(result == [100, 200, 300])
  }

  @Test func diamondGraphDeduplicates() {
    let reader = StubReader(tree: [
      100: [200, 300],
      200: [400],
      300: [400],
    ])
    let result = collectProcessTree(rootPid: 100, reader: reader)
    #expect(result == [100, 200, 300, 400])
  }

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

    let killOrder = Array(collected.reversed())
    #expect(killOrder == [500, 400, 300, 200, 100])
  }
}
