#if os(macOS)
import Foundation
import Testing
@testable import ScribeMac

struct AppConsoleLogTests {
  @Test func dailyPathsUseLocalLaunchDate() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let home = URL(fileURLWithPath: "/tmp/scribe-test-home")
    let morning = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 11, hour: 8)))
    let evening = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 11, hour: 23)))
    let tomorrow = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 12, hour: 1)))
    #expect(AppConsoleLog.fileURL(home: home, date: morning).path == "/tmp/scribe-test-home/logs/remote-26-09-11.log")
    #expect(AppConsoleLog.fileURL(home: home, date: morning) == AppConsoleLog.fileURL(home: home, date: evening))
    #expect(AppConsoleLog.fileURL(home: home, date: tomorrow).lastPathComponent == "remote-26-09-12.log")
  }
}
#endif
