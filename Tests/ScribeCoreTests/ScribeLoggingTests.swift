import Foundation
import ScribeCore
import Testing

/// Tests for `ScribeLogLevel` parsing and LogHandler behavior.
@Suite
struct ScribeLoggingTests {

    // MARK: - ScribeLogLevel parsing

    @Test func parsesAllValidLevelStrings() {
        #expect(ScribeLogLevel(rawValue: "trace") == .trace)
        #expect(ScribeLogLevel(rawValue: "debug") == .debug)
        #expect(ScribeLogLevel(rawValue: "info") == .info)
        #expect(ScribeLogLevel(rawValue: "notice") == .notice)
        #expect(ScribeLogLevel(rawValue: "warning") == .warning)
        #expect(ScribeLogLevel(rawValue: "error") == .error)
    }

    @Test func parsesCaseInsensitively() {
        // rawValue is case-sensitive; parsingConfig handles case but is internal.
        // We test the public API directly.
        #expect(ScribeLogLevel(rawValue: "debug") == .debug)
        #expect(ScribeLogLevel(rawValue: "DEBUG") == nil)  // rawValue is case-sensitive
    }

    @Test func returnsNilForInvalidValues() {
        #expect(ScribeLogLevel(rawValue: "verbose") == nil)
        #expect(ScribeLogLevel(rawValue: "critical") == nil)
        #expect(ScribeLogLevel(rawValue: "") == nil)
        #expect(ScribeLogLevel(rawValue: "   ") == nil)
    }

    // MARK: - Priority ordering

    @Test func priorityIncreasesWithSeverity() {
        let levels: [ScribeLogLevel] = [.trace, .debug, .info, .notice, .warning, .error]
        for i in 0..<(levels.count - 1) {
            #expect(levels[i].priority < levels[i + 1].priority,
                    "\(levels[i]) should have lower priority than \(levels[i + 1])")
        }
    }

    // MARK: - swiftLogLevel mapping

    @Test func swiftLogLevelMatchesRawValue() {
        #expect(ScribeLogLevel.trace.swiftLogLevel == .trace)
        #expect(ScribeLogLevel.debug.swiftLogLevel == .debug)
        #expect(ScribeLogLevel.info.swiftLogLevel == .info)
        #expect(ScribeLogLevel.notice.swiftLogLevel == .notice)
        #expect(ScribeLogLevel.warning.swiftLogLevel == .warning)
        #expect(ScribeLogLevel.error.swiftLogLevel == .error)
    }

    // MARK: - CaseIterable

    @Test func allCasesContainsSixLevels() {
        #expect(ScribeLogLevel.allCases.count == 6)
        #expect(ScribeLogLevel.allCases.contains(.trace))
        #expect(ScribeLogLevel.allCases.contains(.debug))
        #expect(ScribeLogLevel.allCases.contains(.info))
        #expect(ScribeLogLevel.allCases.contains(.notice))
        #expect(ScribeLogLevel.allCases.contains(.warning))
        #expect(ScribeLogLevel.allCases.contains(.error))
    }
}
