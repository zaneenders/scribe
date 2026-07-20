import Foundation
import Logging
import Testing

@testable import ScribeCore

// MARK: - Mock ProcessTreeReader

private struct MockProcessTreeReader: ProcessTreeReader {
    let children: [pid_t: [pid_t]]

    init(_ dict: [pid_t: [pid_t]]) {
        self.children = dict
    }

    func children(of pid: pid_t) -> [pid_t] {
        children[pid] ?? []
    }
}

@Suite
struct ProcessKillerTests {

    // MARK: - collectProcessTree

    @Test("collectProcessTree includes root PID")
    func collectProcessTreeIncludesRoot() {
        let reader = MockProcessTreeReader([:])
        let pids = collectProcessTree(rootPid: 100, reader: reader)
        #expect(pids == [100])
    }

    @Test("collectProcessTree collects single-level children")
    func collectProcessTreeSingleLevel() {
        let reader = MockProcessTreeReader([
            100: [200, 201],
            200: [],
            201: [],
        ])
        let pids = collectProcessTree(rootPid: 100, reader: reader)

        #expect(pids.contains(100))
        #expect(pids.contains(200))
        #expect(pids.contains(201))
        #expect(pids.count == 3)
    }

    @Test("collectProcessTree collects nested children")
    func collectProcessTreeNested() {
        let reader = MockProcessTreeReader([
            100: [200],
            200: [300, 301],
            300: [],
            301: [400],
            400: [],
        ])
        let pids = collectProcessTree(rootPid: 100, reader: reader)

        #expect(pids.contains(100))
        #expect(pids.contains(200))
        #expect(pids.contains(300))
        #expect(pids.contains(301))
        #expect(pids.contains(400))
        #expect(pids.count == 5)
    }

    @Test("collectProcessTree filters out PIDs <= 2")
    func collectProcessTreeFiltersLowPIDs() {
        let reader = MockProcessTreeReader([
            100: [1, 2, 200, 0],
            200: [],
        ])
        let pids = collectProcessTree(rootPid: 100, reader: reader)

        #expect(!pids.contains(1))
        #expect(!pids.contains(2))
        #expect(!pids.contains(0))
        #expect(pids.contains(200))
        #expect(pids.count == 2)
    }

    @Test("collectProcessTree avoids duplicates")
    func collectProcessTreeAvoidsDuplicates() {
        let reader = MockProcessTreeReader([
            100: [200, 300],
            200: [300],  // 300 is a child of both 100 and 200
            300: [],
        ])
        let pids = collectProcessTree(rootPid: 100, reader: reader)

        #expect(pids.filter { $0 == 300 }.count == 1)
        #expect(pids.count == 3)
    }

    @Test("collectProcessTree handles empty children")
    func collectProcessTreeEmptyChildren() {
        let reader = MockProcessTreeReader([
            100: [],
        ])
        let pids = collectProcessTree(rootPid: 100, reader: reader)
        #expect(pids == [100])
    }

    @Test("collectProcessTree handles unknown PID gracefully")
    func collectProcessTreeUnknownPID() {
        let reader = MockProcessTreeReader([:])
        let pids = collectProcessTree(rootPid: 99999, reader: reader)
        #expect(pids == [99999])
    }

    // MARK: - PgroupKiller

    @Test("PgroupKiller initializes without crashing")
    func pgroupKillerInitializes() {
        let killer = PgroupKiller()
        _ = killer  // Ensure it doesn't crash on init
    }

    // MARK: - ProcTreeKiller with mock reader

    @Test("ProcTreeKiller initializes with mock reader")
    func procTreeKillerInitializes() {
        let reader = MockProcessTreeReader([:])
        let killer = ProcTreeKiller(reader: reader)
        _ = killer
    }
}
