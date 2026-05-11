import Foundation
import Testing

@testable import ScribeCore

// MARK: - Shell.Result.exitCodeForJSON tests

@Suite
struct ShellResultTests {

    // MARK: - exitCodeForJSON

    @Test func exitedCodeMapsDirectly() {
        let stdoutFile = ScribeFilePath("/tmp/stdout.txt")
        let stderrFile = ScribeFilePath("/tmp/stderr.txt")
        let result = Shell.Result(
            exitCode: .exited(0),
            stdoutFile: stdoutFile,
            stderrFile: stderrFile,
            pid: 12345
        )
        #expect(result.exitCodeForJSON == 0)
    }

    @Test func exitedNonZeroCodeMapsDirectly() {
        let stdoutFile = ScribeFilePath("/tmp/stdout.txt")
        let stderrFile = ScribeFilePath("/tmp/stderr.txt")
        let result = Shell.Result(
            exitCode: .exited(42),
            stdoutFile: stdoutFile,
            stderrFile: stderrFile,
            pid: 12345
        )
        #expect(result.exitCodeForJSON == 42)
    }

    @Test func exitedCode127MapsDirectly() {
        let stdoutFile = ScribeFilePath("/tmp/stdout.txt")
        let stderrFile = ScribeFilePath("/tmp/stderr.txt")
        let result = Shell.Result(
            exitCode: .exited(127),
            stdoutFile: stdoutFile,
            stderrFile: stderrFile,
            pid: 12345
        )
        #expect(result.exitCodeForJSON == 127)
    }

    #if !os(Windows)
    @Test func signaledMapsTo128PlusSignal() {
        let stdoutFile = ScribeFilePath("/tmp/stdout.txt")
        let stderrFile = ScribeFilePath("/tmp/stderr.txt")
        let result = Shell.Result(
            exitCode: .signaled(9),
            stdoutFile: stdoutFile,
            stderrFile: stderrFile,
            pid: 12345
        )
        #expect(result.exitCodeForJSON == 137)  // 128 + 9
    }

    @Test func signaledSIGKILLMapsCorrectly() {
        let stdoutFile = ScribeFilePath("/tmp/stdout.txt")
        let stderrFile = ScribeFilePath("/tmp/stderr.txt")
        let result = Shell.Result(
            exitCode: .signaled(15),
            stdoutFile: stdoutFile,
            stderrFile: stderrFile,
            pid: 12345
        )
        #expect(result.exitCodeForJSON == 143)  // 128 + 15
    }
    #endif
}

// MARK: - Duration.microseconds tests

@Suite
struct DurationMicrosecondsTests {

    @Test func zeroDuration() {
        let d: Duration = .zero
        #expect(d.microseconds == 0)
    }

    @Test func oneSecond() {
        let d: Duration = .seconds(1)
        #expect(d.microseconds == 1_000_000)
    }

    @Test func oneMillisecond() {
        let d: Duration = .milliseconds(1)
        #expect(d.microseconds == 1_000)
    }

    @Test func oneMicrosecond() {
        let d: Duration = .microseconds(1)
        #expect(d.microseconds == 1)
    }

    @Test func twoSeconds() {
        let d: Duration = .seconds(2)
        #expect(d.microseconds == 2_000_000)
    }

    @Test func mixedSecondsAndAttoseconds() {
        // 1 second + 500 milliseconds = 1.5 seconds = 1,500,000 microseconds
        let d: Duration = .seconds(1) + .milliseconds(500)
        #expect(d.microseconds == 1_500_000)
    }

    @Test func subMillisecondDuration() {
        let d: Duration = .microseconds(500)
        #expect(d.microseconds == 500)
    }
}
