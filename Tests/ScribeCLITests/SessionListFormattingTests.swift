import Foundation
import Testing
@testable import ScribeCLI

/// Tests for `--list-sessions` output formatting: relative time strings and
/// the column-aligned session line format.
@Suite
struct SessionListFormattingTests {

  // MARK: - relativeTime

  @Test func relativeTimeJustNow() {
    let now = Date()
    let result = ScribeCLI().relativeTime(from: now)
    #expect(result == "just now")
  }

  @Test func relativeTimeFuture() {
    let future = Date().addingTimeInterval(10)
    let result = ScribeCLI().relativeTime(from: future)
    #expect(result == "just now")
  }

  @Test func relativeTimeSeconds() {
    let date = Date().addingTimeInterval(-30)
    let result = ScribeCLI().relativeTime(from: date)
    #expect(result == "30s ago")
  }

  @Test func relativeTimeOneMinute() {
    let date = Date().addingTimeInterval(-90)
    let result = ScribeCLI().relativeTime(from: date)
    #expect(result == "1m ago")
  }

  @Test func relativeTimeMinutes() {
    let date = Date().addingTimeInterval(-15 * 60)
    let result = ScribeCLI().relativeTime(from: date)
    #expect(result == "15m ago")
  }

  @Test func relativeTimeOneHour() {
    let date = Date().addingTimeInterval(-90 * 60)
    let result = ScribeCLI().relativeTime(from: date)
    #expect(result == "1h ago")
  }

  @Test func relativeTimeHours() {
    let date = Date().addingTimeInterval(-6 * 3600)
    let result = ScribeCLI().relativeTime(from: date)
    #expect(result == "6h ago")
  }

  @Test func relativeTimeOneDay() {
    let date = Date().addingTimeInterval(-30 * 3600)
    let result = ScribeCLI().relativeTime(from: date)
    #expect(result == "1d ago")
  }

  @Test func relativeTimeDays() {
    let date = Date().addingTimeInterval(-4 * 86400)
    let result = ScribeCLI().relativeTime(from: date)
    #expect(result == "4d ago")
  }

  @Test func relativeTimeOneWeek() {
    let date = Date().addingTimeInterval(-10 * 86400)
    let result = ScribeCLI().relativeTime(from: date)
    #expect(result == "1w ago")
  }

  @Test func relativeTimeWeeks() {
    let date = Date().addingTimeInterval(-21 * 86400)
    let result = ScribeCLI().relativeTime(from: date)
    #expect(result == "3w ago")
  }

  @Test func relativeTimeBoundary59Seconds() {
    let date = Date().addingTimeInterval(-59)
    let result = ScribeCLI().relativeTime(from: date)
    #expect(result == "59s ago")
  }

  @Test func relativeTimeBoundary60Seconds() {
    let date = Date().addingTimeInterval(-60)
    let result = ScribeCLI().relativeTime(from: date)
    #expect(result == "1m ago")
  }

  @Test func relativeTimeBoundary59Minutes() {
    let date = Date().addingTimeInterval(-59 * 60)
    let result = ScribeCLI().relativeTime(from: date)
    #expect(result == "59m ago")
  }

  @Test func relativeTimeBoundary60Minutes() {
    let date = Date().addingTimeInterval(-60 * 60)
    let result = ScribeCLI().relativeTime(from: date)
    #expect(result == "1h ago")
  }

  // MARK: - formatSessionLine alignment

  /// Strips ANSI SGR escape sequences so column positions can be verified.
  private func stripANSI(_ s: String) -> String {
    s.replacingOccurrences(
      of: "\u{001B}\\[[0-9;]*[a-zA-Z]",
      with: "",
      options: .regularExpression
    )
  }

  @Test func formatSessionLineColumnAlignment() {
    // Rows with varying time widths and msg counts — columns must stay aligned.
    let rows: [(id: String, count: Int, when: String, cwd: String)] = [
      ("8FFC6215", 87, "2m ago", "~/.scribe/Code/scribe"),
      ("ECAAB88F", 1, "20m ago", "~/.config/scribe"),
      ("885E2CFB", 42, "25m ago", "~"),
      ("78327AE7", 100, "6h ago", "~/.scribe/Code/scribe"),
      ("CFDF75D4", 1, "10h ago", "~/.scribe/Code/scribe"),
    ]

    let stripped = rows.map {
      stripANSI(
        ScribeCLI().formatSessionLine(
          shortId: $0.id, msgCount: $0.count, when: $0.when, cwd: $0.cwd)
      )
    }

    // Every row's shortId must start at the same column.
    var idStarts = [Int]()
    for (i, line) in stripped.enumerated() {
      guard let r = line.range(of: rows[i].id) else {
        #expect(Bool(false), "Missing id in line \(i): \(line)")
        continue
      }
      idStarts.append(line.distance(from: line.startIndex, to: r.lowerBound))
    }
    let expectedId = idStarts.first!
    for (i, start) in idStarts.enumerated() {
      #expect(start == expectedId, "Line \(i) id at \(start), expected \(expectedId): \(stripped[i])")
    }

    // Every row's cwd must start at the same column.
    var cwdStarts = [Int]()
    for (i, line) in stripped.enumerated() {
      let cwd = rows[i].cwd
      guard let r = line.range(of: cwd) else {
        #expect(Bool(false), "Missing cwd in line \(i): \(line)")
        continue
      }
      cwdStarts.append(line.distance(from: line.startIndex, to: r.lowerBound))
    }
    let expectedCwd = cwdStarts.first!
    for (i, start) in cwdStarts.enumerated() {
      #expect(start == expectedCwd, "Line \(i) cwd at \(start), expected \(expectedCwd): \(stripped[i])")
    }
  }

  @Test func formatSessionLineContainsShortId() {
    let line = ScribeCLI().formatSessionLine(
      shortId: "DEADBEEF", msgCount: 5, when: "1h ago", cwd: "~/proj")
    let stripped = stripANSI(line)
    #expect(stripped.contains("DEADBEEF"))
  }

  @Test func formatSessionLineUsesSingularMsg() {
    let line = ScribeCLI().formatSessionLine(
      shortId: "AAAAAAAA", msgCount: 1, when: "1m ago", cwd: "~")
    let stripped = stripANSI(line)
    #expect(stripped.contains("1 msg"))
    #expect(!stripped.contains("1 msgs"))
  }

  @Test func formatSessionLineUsesPluralMsgs() {
    let line = ScribeCLI().formatSessionLine(
      shortId: "AAAAAAAA", msgCount: 0, when: "1m ago", cwd: "~")
    let stripped = stripANSI(line)
    #expect(stripped.contains("0 msgs"))
  }

  @Test func formatSessionLineTimeColAlwaysNineChars() {
    // The time column should always occupy exactly 9 visible characters
    // regardless of the input string length (≤ 8 chars input).
    let cases = ["just now", "5s ago", "59s ago", "1m ago", "59m ago", "1h ago", "23h ago", "1d ago"]

    for when in cases {
      let line = ScribeCLI().formatSessionLine(
        shortId: "BBBBBBBB", msgCount: 1, when: when, cwd: "~")
      let stripped = stripANSI(line)

      // The time column is the first 9 chars. After stripping ANSI,
      // the shortId "BBBBBBBB" should start at index 11 (9 time + 2 spaces).
      guard let idRange = stripped.range(of: "BBBBBBBB") else {
        #expect(Bool(false), "Missing UUID in: \(stripped)")
        continue
      }
      let idStart = stripped.distance(from: stripped.startIndex, to: idRange.lowerBound)
      #expect(
        idStart == 11,
        "Time '\(when)' → id starts at \(idStart), expected 11: '\(stripped)'"
      )
    }
  }

  @Test func formatSessionLineMsgColAlwaysEightChars() {
    // The msg column should always occupy exactly 8 visible characters.
    let cases = [(0, "0 msgs"), (1, "1 msg"), (9, "9 msgs"), (10, "10 msgs"), (99, "99 msgs"), (100, "100 msgs"), (9999, "9999 ms")]

    for (count, _) in cases {
      let line = ScribeCLI().formatSessionLine(
        shortId: "CCCCCCCC", msgCount: count, when: "1m ago", cwd: "~")
      let stripped = stripANSI(line)

      // After 9 (time) + 2 (gap) + 8 (uuid) + 2 (gap) = 21 chars, the msg column starts.
      // The cwd "~" should start at 21 + 8 (msg) + 2 (gap) = 31.
      guard let cwdRange = stripped.range(of: "~") else {
        #expect(Bool(false), "Missing cwd in: \(stripped)")
        continue
      }
      let cwdStart = stripped.distance(from: stripped.startIndex, to: cwdRange.lowerBound)
      #expect(
        cwdStart == 31,
        "Msg count \(count) → cwd starts at \(cwdStart), expected 31: '\(stripped)'"
      )
    }
  }
}
