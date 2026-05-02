import Foundation
import ScribeLLM

/// Shared presentation helpers for token counts in the CLI.
public enum ScribeUsageFormatting {
  private static let groupingFormatter: NumberFormatter = {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.locale = Locale(identifier: "en_US_POSIX")
    f.groupingSeparator = ","
    f.usesGroupingSeparator = true
    return f
  }()

  public static func groupingInt(_ n: Int) -> String {
    groupingFormatter.string(from: NSNumber(value: n)) ?? String(n)
  }
}

extension Components.Schemas.CompletionUsage {
  /// Best-effort counts for one provider response when presenting usage in the CLI.
  ///
  /// Some servers omit `total_tokens`; if so, uses `prompt_tokens + completion_tokens` when those are present.
  public var scribeReportedPromptCompletionTotal: (prompt: Int, completion: Int, total: Int)? {
    let p = promptTokens ?? 0
    let c = completionTokens ?? 0
    let statedTotal = totalTokens ?? 0
    let t = statedTotal > 0 ? statedTotal : (p + c > 0 ? p + c : 0)
    guard p > 0 || c > 0 || t > 0 else { return nil }
    return (p, c, t)
  }
}
