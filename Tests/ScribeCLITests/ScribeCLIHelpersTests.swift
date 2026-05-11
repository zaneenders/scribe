import Foundation
import Testing

@testable import ScribeCLI

@Suite
struct ScribeCLIHelpersTests {
  // Use a dummy instance since relativeTime and formatSessionLine are instance methods.
  private let cli = ScribeCLI()

  // MARK: - relativeTime

  @Test
  func justNow() {
    let now = Date()
    let result = cli.relativeTime(from: now)
    #expect(result == "just now")
  }

  @Test
  func secondsAgo() {
    let date = Date().addingTimeInterval(-30)
    let result = cli.relativeTime(from: date)
    #expect(result == "30s ago")
  }

  @Test
  func oneMinuteAgo() {
    let date = Date().addingTimeInterval(-90)
    let result = cli.relativeTime(from: date)
    #expect(result == "1m ago")
  }

  @Test
  func minutesAgo() {
    let date = Date().addingTimeInterval(-300)  // 5 minutes
    let result = cli.relativeTime(from: date)
    #expect(result == "5m ago")
  }

  @Test
  func oneHourAgo() {
    let date = Date().addingTimeInterval(-5400)  // 1.5 hours
    let result = cli.relativeTime(from: date)
    #expect(result == "1h ago")
  }

  @Test
  func hoursAgo() {
    let date = Date().addingTimeInterval(-7200)  // 2 hours
    let result = cli.relativeTime(from: date)
    #expect(result == "2h ago")
  }

  @Test
  func oneDayAgo() {
    let date = Date().addingTimeInterval(-90_000)  // ~25 hours
    let result = cli.relativeTime(from: date)
    #expect(result == "1d ago")
  }

  @Test
  func daysAgo() {
    let date = Date().addingTimeInterval(-259_200)  // 3 days
    let result = cli.relativeTime(from: date)
    #expect(result == "3d ago")
  }

  @Test
  func oneWeekAgo() {
    let date = Date().addingTimeInterval(-950_400)  // 11 days
    let result = cli.relativeTime(from: date)
    #expect(result == "1w ago")
  }

  @Test
  func weeksAgo() {
    let date = Date().addingTimeInterval(-1_814_400)  // 3 weeks
    let result = cli.relativeTime(from: date)
    #expect(result == "3w ago")
  }

  // MARK: - formatSessionLine

  @Test
  func formatSessionLineIncludesAllFields() {
    let line = cli.formatSessionLine(
      shortId: "abc12345",
      when: "5m ago",
      cwd: "/home/user/project",
      version: "abc123f"
    )
    #expect(line.contains("abc12345"))
    #expect(line.contains("5m ago"))
    #expect(line.contains("/home/user/project"))
    #expect(line.contains("abc123f"))
  }

  @Test
  func formatSessionLinePadsTimeColumn() {
    let line = cli.formatSessionLine(
      shortId: "abc12345",
      when: "5m ago",
      cwd: "/tmp",
      version: "v1"
    )
    // "5m ago" is 6 chars, padded to 9 with 3 spaces.
    #expect(line.contains("5m ago   \u{001B}[0m"))
  }

  @Test
  func formatSessionLinePadsLongTime() {
    // "just now" is 8 chars, should be padded to 9 with 1 space.
    let line = cli.formatSessionLine(
      shortId: "abc12345",
      when: "just now",
      cwd: "/tmp",
      version: "v1"
    )
    #expect(line.contains("just now \u{001B}[0m"))
  }

  @Test
  func formatSessionLineContainsANSIEscapes() {
    let line = cli.formatSessionLine(
      shortId: "abc12345",
      when: "1h ago",
      cwd: "/tmp",
      version: "v1"
    )
    // Should contain dim escapes for time and version.
    #expect(line.contains("\u{001B}[2m"))
    #expect(line.contains("\u{001B}[0m"))
    // Should contain cyan escape for session ID.
    #expect(line.contains("\u{001B}[36m"))
  }
}
