import Foundation

/// Layout for a token usage panel using ``ANSI`` (primitive building block).
public enum UsageBanner {
  public static func line(
    promptTokens: Int?,
    completionTokens: Int?,
    totalTokens: Int?
  ) -> String? {
    guard promptTokens != nil || completionTokens != nil || totalTokens != nil else { return nil }
    let inStr = promptTokens.map(String.init) ?? "—"
    let outStr = completionTokens.map(String.init) ?? "—"
    let sumStr = totalTokens.map(String.init) ?? "—"

    let innerVisible = "◆ \(inStr) in  ·  \(outStr) out  ·  \(sumStr) Σ ◆"
    let targetWidth = max(innerVisible.count + 10, 54)
    let sidePad = max(0, targetWidth - innerVisible.count)
    let padL = sidePad / 2
    let padR = sidePad - padL

    let bg = ANSI.usagePanelBg
    let rail = ANSI.usagePanelRailBg
    let m = ANSI.usagePanelMuted
    let ni = ANSI.usagePanelIn
    let no = ANSI.usagePanelOut
    let ns = ANSI.usagePanelSum
    let x = ANSI.reset

    let railRow = "  \(rail)\(m)" + String(repeating: "\u{00B7}", count: targetWidth) + "\(x)"
    let midInner =
      "\(m)◆ \(ni)\(inStr)\(m) in  ·  \(no)\(outStr)\(m) out  ·  \(ns)\(sumStr)\(m)\u{001B}[22m Σ ◆"
    let midRow =
      "\(bg)" + String(repeating: " ", count: padL) + midInner + String(repeating: " ", count: padR)
      + "\(x)"

    return "\n\(railRow)\n  \(midRow)\n\(railRow)"
  }
}
