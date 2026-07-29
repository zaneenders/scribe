import Foundation

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
