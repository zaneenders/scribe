import Foundation
import Logging
import ScribeCLI
import Testing

// MARK: - SharedLogWriter + ScribeLogLevel tests

@Suite(.serialized)
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
    #expect(ScribeLogLevel(rawValue: "debug") == .debug)
    #expect(ScribeLogLevel(rawValue: "DEBUG") == nil)
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
      #expect(
        levels[i].priority < levels[i + 1].priority,
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

  // MARK: - SharedLogWriter

  @Test func sharedLogWriterDefaultsToTraceLevel() {
    #expect(SharedLogWriter.logLevel == .trace)
  }

  @Test func swapChangesLogLevel() {
    let collector = CollectingWriter()
    SharedLogWriter.swap(
      to: LockedDataWriter { data in collector.append(data) }, level: .warning)
    #expect(SharedLogWriter.logLevel == .warning)
    restoreDefaultWriter()
  }

  @Test func writeRoutesThroughCurrentWriter() {
    let collector = CollectingWriter()
    SharedLogWriter.swap(
      to: LockedDataWriter { data in collector.append(data) }, level: .trace)

    SharedLogWriter.write(Data("hello".utf8))
    #expect(collector.string == "hello")

    SharedLogWriter.write(Data(" world".utf8))
    #expect(collector.string == "hello world")

    restoreDefaultWriter()
  }

  // MARK: - Metadata rendering via SharedLogWriter

  @Test func metadataRenderedAsSortedKeyValuePairs() {
    let collector = CollectingWriter()
    SharedLogWriter.swap(
      to: LockedDataWriter { data in collector.append(data) }, level: .trace)

    // Write a log line with metadata manually to test rendering.
    bootstrapScribeLogging()
    let logger = Logger(label: "scribe.test.meta")
    logger.info("action completed", metadata: ["pid": "1234", "shell_id": "abc"])

    let line = collector.lastLine
    #expect(line.contains("pid=1234"))
    #expect(line.contains("shell_id=abc"))
    #expect(
      line.range(of: "pid=1234")!.lowerBound < line.range(of: "shell_id=abc")!.lowerBound)

    restoreDefaultWriter()
  }

  @Test func noMetadataProducesCleanLine() {
    let collector = CollectingWriter()
    SharedLogWriter.swap(
      to: LockedDataWriter { data in collector.append(data) }, level: .trace)

    bootstrapScribeLogging()
    let logger = Logger(label: "scribe.test.nometa")
    logger.trace("simple message")

    let line = collector.lastLine
    #expect(line.contains("[trace] simple message"))
    #expect(!line.hasSuffix(" \n"))

    restoreDefaultWriter()
  }

  @Test func logLinesIncludeTimestamp() {
    let collector = CollectingWriter()
    SharedLogWriter.swap(
      to: LockedDataWriter { data in collector.append(data) }, level: .trace)

    bootstrapScribeLogging()
    let logger = Logger(label: "scribe.test.timestamp")
    logger.info("timestamped")

    let line = collector.lastLine
    let timestampRegex = try! NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}T"#)
    let range = NSRange(line.startIndex..<line.endIndex, in: line)
    #expect(timestampRegex.firstMatch(in: line, range: range) != nil)

    restoreDefaultWriter()
  }
}

// MARK: - Helpers

private final class CollectingWriter: @unchecked Sendable {
  private var buffer = Data()
  private let lock = NSLock()

  func append(_ data: Data) {
    lock.lock()
    buffer.append(data)
    lock.unlock()
  }

  var string: String {
    lock.lock()
    defer { lock.unlock() }
    return String(data: buffer, encoding: .utf8) ?? ""
  }

  var lines: [String] {
    string.split(separator: "\n", omittingEmptySubsequences: false)
      .filter { !$0.isEmpty }
      .map(String.init)
  }

  var lastLine: String { lines.last ?? "" }
}

private func restoreDefaultWriter() {
  SharedLogWriter.swap(
    to: LockedDataWriter { data in try? FileHandle.standardError.write(contentsOf: data) },
    level: .trace)
}
