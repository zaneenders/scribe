import Foundation
import ScribeCodexAuth
import Testing

struct CodexUsageTests {
  @Test func decodesUsageWindowsAndClampsRemainingPercentage() throws {
    let data = Data(
      """
      {"rate_limit": {
        "primary_window": {"used_percent": 32, "reset_at": 1800000000, "limit_window_seconds": 18000},
        "secondary_window": {"used_percent": 105, "reset_at": 1800600000, "limit_window_seconds": 604800}
      }}
      """.utf8)
    let usage = try JSONDecoder().decode(CodexUsage.self, from: data)
    #expect(usage.rateLimit?.primaryWindow?.remainingPercent == 68)
    #expect(usage.rateLimit?.primaryWindow?.resetAt == 1_800_000_000)
    #expect(usage.rateLimit?.secondaryWindow?.remainingPercent == 0)
  }

  @Test func acceptsUnavailableWindows() throws {
    let usage = try JSONDecoder().decode(CodexUsage.self, from: Data("{\"rate_limit\": null}".utf8))
    #expect(usage.rateLimit == nil)
  }
}
